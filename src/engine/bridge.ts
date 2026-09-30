import { createServer, type Server, type Socket } from "node:net";
import { randomBytes } from "node:crypto";
import type { LogBuffer } from "./logs.js";

export type PeerKind = "host" | "editor" | "unknown";

export interface PeerHello {
  kind: PeerKind;
  protocol?: number;
  pid?: number;
  engine?: Record<string, unknown>;
  project?: string;
  display?: string;
  argv?: string[];
}

export interface Peer {
  kind: PeerKind;
  hello: PeerHello;
  socket: Socket;
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
  cmd: string;
}

export type PeerEvent =
  | { type: "hello"; peer: Peer }
  | { type: "close"; peer: Peer }
  | { type: "event"; peer: Peer; event: string; data: unknown };

/**
 * TCP-мост на 127.0.0.1: Godot-хост и редакторный плагин подключаются к серверу,
 * MCP-сервер выступает клиентом. Протокол — JSON-строки (JSONL) + общий токен.
 */
export class BridgeServer {
  private server: Server | null = null;
  private peers = new Map<string, Peer>();
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private listeners: Array<(e: PeerEvent) => void> = [];
  readonly token = randomBytes(24).toString("hex");
  port = 0;

  constructor(private logs: LogBuffer) {}

  /** Подписка на события моста. Возвращает функцию отписки. */
  on(listener: (e: PeerEvent) => void): () => void {
    this.listeners.push(listener);
    return () => {
      const i = this.listeners.indexOf(listener);
      if (i >= 0) this.listeners.splice(i, 1);
    };
  }

  async listen(preferredPort = 0): Promise<number> {
    if (this.server) return this.port;
    this.server = createServer((socket) => this.accept(socket));
    await new Promise<void>((resolve, reject) => {
      this.server?.once("error", reject);
      this.server?.listen(preferredPort, "127.0.0.1", () => {
        this.server?.removeListener("error", reject);
        resolve();
      });
    });
    const addr = this.server.address();
    this.port = typeof addr === "object" && addr ? addr.port : preferredPort;
    this.logs.pushEvent(`Мост слушает 127.0.0.1:${this.port}`);
    return this.port;
  }

  private emit(e: PeerEvent): void {
    for (const l of this.listeners) l(e);
  }

  private accept(socket: Socket): void {
    socket.setNoDelay(true);
    let buffer = "";
    let peer: Peer | null = null;
    socket.setEncoding("utf8");

    socket.on("data", (chunk: string) => {
      buffer += chunk;
      let idx = buffer.indexOf("\n");
      while (idx !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        if (line.trim()) this.handleLine(line, socket, (p) => (peer = p));
        idx = buffer.indexOf("\n");
      }
      if (buffer.length > 16 * 1024 * 1024) socket.destroy();
    });

    socket.on("error", () => socket.destroy());
    socket.on("close", () => {
      if (peer) {
        this.peers.delete(peerKey(peer));
        this.logs.pushEvent(`Пиер отключился: ${peer.kind} pid=${peer.hello.pid ?? "?"}`);
        this.emit({ type: "close", peer });
      }
    });
  }

  private handleLine(line: string, socket: Socket, setPeer: (p: Peer) => void): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.logs.pushEvent(`Некорректный JSON от пира: ${line.slice(0, 200)}`, "warning");
      return;
    }
    if (msg.type === "hello") {
      if (msg.token !== this.token) {
        this.logs.pushEvent("Отклонено подключение с неверным токеном", "error");
        socket.destroy();
        return;
      }
      const hello = msg as unknown as PeerHello;
      const resolvedKind: PeerKind = hello.kind === "editor" ? "editor" : "host";
      const p: Peer = { kind: resolvedKind, hello, socket };
      setPeer(p);
      // Один хост и один редактор одновременно; новый вытесняет старого.
      for (const [key, existing] of this.peers) {
        if (existing.kind === resolvedKind) {
          this.peers.delete(key);
          existing.socket.destroy();
        }
      }
      this.peers.set(peerKey(p), p);
      this.logs.pushEvent(
        `Подключился ${resolvedKind}: pid=${hello.pid ?? "?"} protocol=${hello.protocol ?? "?"} display=${hello.display ?? "?"}`,
      );
      this.emit({ type: "hello", peer: p });
      return;
    }
    if (msg.type === "res") {
      const id = Number(msg.id);
      const p = this.pending.get(id);
      if (!p) return;
      this.pending.delete(id);
      clearTimeout(p.timer);
      if (msg.ok === true) p.resolve(msg.data);
      else {
        const err = new Error(String(msg.error ?? "Неизвестная ошибка Godot"));
        (err as Error & { code?: string }).code = String(msg.code ?? "error");
        p.reject(err);
      }
      return;
    }
    if (msg.type === "event") {
      const name = String(msg.event);
      const data = msg.data;
      if (name === "step_complete" || name === "runtime_started" || name === "host_shutdown") {
        this.logs.pushEvent(`Событие ${name}: ${safeJson(data)}`, name === "host_shutdown" ? "warning" : "info");
      }
      for (const p of this.peers.values()) this.emit({ type: "event", peer: p, event: name, data });
    }
  }

  private send(peer: Peer, payload: Record<string, unknown>): void {
    if (peer.socket.destroyed) return;
    peer.socket.write(JSON.stringify(payload) + "\n");
  }

  /** Отправляет команду пиру и ждёт ответа. */
  request(
    kind: PeerKind,
    cmd: string,
    params: Record<string, unknown>,
    timeoutMs: number,
  ): Promise<unknown> {
    const peer = this.getPeer(kind);
    if (!peer) {
      return Promise.reject(new Error(`Нет подключённого пиера типа "${kind}"`));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Таймаут ${timeoutMs} мс на команду ${cmd}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, cmd });
      this.send(peer, { type: "req", id, cmd, params });
    });
  }

  notify(peer: Peer, cmd: string, params: Record<string, unknown>): void {
    this.send(peer, { type: "notify", cmd, params });
  }

  getPeer(kind: PeerKind): Peer | undefined {
    for (const p of this.peers.values()) if (p.kind === kind) return p;
    return undefined;
  }

  peersOf(kind: PeerKind): Peer[] {
    return [...this.peers.values()].filter((p) => p.kind === kind);
  }

  rejectAllPending(reason: string): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new Error(reason));
    }
    this.pending.clear();
  }

  async close(): Promise<void> {
    this.rejectAllPending("Мост закрыт");
    for (const p of this.peers.values()) p.socket.destroy();
    this.peers.clear();
    if (this.server) {
      await new Promise<void>((resolve) => this.server?.close(() => resolve()));
      this.server = null;
    }
  }
}

function peerKey(p: Peer): string {
  return `${p.kind}:${p.hello.pid ?? 0}`;
}

function safeJson(v: unknown): string {
  try {
    const s = JSON.stringify(v);
    return s && s.length > 600 ? `${s.slice(0, 600)}…` : (s ?? "");
  } catch {
    return String(v);
  }
}
