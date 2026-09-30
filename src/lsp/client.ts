import { connect, type Socket } from "node:net";
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

export interface Diagnostic {
  severity: "error" | "warning" | "info" | "hint";
  message: string;
  line: number;
  column: number;
  end_line?: number;
  end_column?: number;
  code?: string;
  source?: string;
}

interface Pending {
  resolve: (v: any) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * Клиент GDScript Language Server из редактора Godot (--lsp-port).
 * Транспорт — стандартный LSP поверх TCP (заголовок Content-Length).
 */
export class GdscriptLsp {
  private socket: Socket | null = null;
  private buffer = Buffer.alloc(0);
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private diagnostics = new Map<string, Diagnostic[]>();
  private open = new Set<string>();
  private notifications: Array<(method: string, params: any) => void> = [];
  private ready = false;
  serverInfo: Record<string, unknown> = {};

  constructor(
    private host: string,
    private port: number,
    private projectRoot: string,
    private timeoutMs = 20_000,
  ) {}

  isReady(): boolean {
    return this.ready;
  }

  async connect(): Promise<void> {
    if (this.socket && this.ready) return;
    await new Promise<void>((resolve, reject) => {
      const socket = connect({ host: this.host, port: this.port });
      socket.setNoDelay(true);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`Таймаут подключения к LSP ${this.host}:${this.port}`));
      }, this.timeoutMs);
      socket.once("connect", () => {
        clearTimeout(timer);
        this.socket = socket;
        socket.on("data", (d: Buffer) => this.onData(Buffer.isBuffer(d) ? d : Buffer.from(d)));
        socket.on("close", () => {
          this.ready = false;
          for (const [, p] of this.pending) {
            clearTimeout(p.timer);
            p.reject(new Error("LSP-соединение закрыто"));
          }
          this.pending.clear();
        });
        socket.on("error", () => socket.destroy());
        resolve();
      });
      socket.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
    const init = await this.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(this.projectRoot).href,
      rootPath: this.projectRoot,
      capabilities: {
        textDocument: {
          synchronization: { dynamicRegistration: false, didSave: true },
          hover: { contentFormat: ["markdown", "plaintext"] },
          completion: { completionItem: { snippetSupport: false } },
          definition: { linkSupport: true },
          documentSymbol: { hierarchicalDocumentSymbolSupport: true },
          publishDiagnostics: { relatedInformation: false },
        },
        workspace: { workspaceFolders: true, symbol: {} },
        general: { markdown: { allowedTags: [] } },
      },
      workspaceFolders: [{ uri: pathToFileURL(this.projectRoot).href, name: path.basename(this.projectRoot) }],
    });
    this.serverInfo = (init ?? {}) as Record<string, unknown>;
    this.notify("initialized", {});
    this.ready = true;
  }

  private onData(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.buffer.subarray(0, headerEnd).toString("utf8");
      const m = /content-length:\s*(\d+)/i.exec(header);
      if (!m) {
        this.buffer = this.buffer.subarray(headerEnd + 4);
        continue;
      }
      const length = Number.parseInt(m[1] ?? "0", 10);
      if (this.buffer.length < headerEnd + 4 + length) return;
      const body = this.buffer.subarray(headerEnd + 4, headerEnd + 4 + length).toString("utf8");
      this.buffer = this.buffer.subarray(headerEnd + 4 + length);
      try {
        this.dispatch(JSON.parse(body));
      } catch {
        /* повреждённое сообщение игнорируем */
      }
    }
  }

  private dispatch(msg: any): void {
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`${msg.error.message ?? "LSP error"} (code ${msg.error.code ?? "?"})`));
      else p.resolve(msg.result);
      return;
    }
    if (msg.method === "textDocument/publishDiagnostics") {
      const uri = String(msg.params?.uri ?? "");
      const list: Diagnostic[] = (msg.params?.diagnostics ?? []).map((d: any) => ({
        severity: severityName(d.severity),
        message: String(d.message ?? ""),
        line: (d.range?.start?.line ?? 0) + 1,
        column: (d.range?.start?.character ?? 0) + 1,
        end_line: d.range?.end?.line !== undefined ? d.range.end.line + 1 : undefined,
        end_column: d.range?.end?.character !== undefined ? d.range.end.character + 1 : undefined,
        code: d.code !== undefined ? String(d.code) : undefined,
        source: d.source,
      }));
      if (list.length) this.diagnostics.set(uri, list);
      else this.diagnostics.delete(uri);
    }
    for (const cb of this.notifications) cb(String(msg.method), msg.params);
  }

  onNotification(cb: (method: string, params: any) => void): void {
    this.notifications.push(cb);
  }

  private send(payload: Record<string, unknown>): void {
    if (!this.socket || this.socket.destroyed) throw new Error("LSP не подключён");
    const body = Buffer.from(JSON.stringify(payload), "utf8");
    this.socket.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.socket.write(body);
  }

  private request(method: string, params: unknown, timeoutMs = this.timeoutMs): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Таймаут LSP-запроса ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.send({ jsonrpc: "2.0", id, method, params });
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err as Error);
      }
    });
  }

  private notify(method: string, params: unknown): void {
    this.send({ jsonrpc: "2.0", method, params });
  }

  private uriFor(absPath: string): string {
    return pathToFileURL(absPath).href;
  }

  /** Открывает документ на сервере и ждёт диагностику. */
  async openFile(absPath: string, waitMs = 700): Promise<Diagnostic[]> {
    const uri = this.uriFor(absPath);
    if (!existsSync(absPath)) throw new Error(`Файл не найден: ${absPath}`);
    const text = readFileSync(absPath, "utf8");
    this.notify("textDocument/didOpen", {
      textDocument: { uri, languageId: "gdscript", version: 1, text },
    });
    this.open.add(uri);
    await new Promise((r) => setTimeout(r, waitMs));
    return this.diagnostics.get(uri) ?? [];
  }

  async openMany(absPaths: string[]): Promise<Map<string, Diagnostic[]>> {
    const out = new Map<string, Diagnostic[]>();
    for (const p of absPaths) {
      out.set(p, await this.openFile(p, 400));
    }
    return out;
  }

  async notifyChanged(absPath: string): Promise<void> {
    const uri = this.uriFor(absPath);
    if (!this.open.has(uri)) return;
    this.notify("textDocument/didChange", {
      textDocument: { uri, version: Date.now() },
      contentChanges: [{ text: readFileSync(absPath, "utf8") }],
    });
  }

  diagnosticsFor(absPath: string): Diagnostic[] {
    return this.diagnostics.get(this.uriFor(absPath)) ?? [];
  }

  allDiagnostics(): Array<{ file: string; diagnostics: Diagnostic[] }> {
    return [...this.diagnostics.entries()].map(([uri, diagnostics]) => ({
      file: decodeURI(uri.replace("file://", "")),
      diagnostics,
    }));
  }

  async hover(absPath: string, line: number, character: number): Promise<unknown> {
    await this.openFile(absPath, 150);
    return this.request("textDocument/hover", {
      textDocument: { uri: this.uriFor(absPath) },
      position: { line: Math.max(0, line - 1), character: Math.max(0, character - 1) },
    });
  }

  async definition(absPath: string, line: number, character: number): Promise<unknown> {
    await this.openFile(absPath, 150);
    return this.request("textDocument/definition", {
      textDocument: { uri: this.uriFor(absPath) },
      position: { line: Math.max(0, line - 1), character: Math.max(0, character - 1) },
    });
  }

  async completion(absPath: string, line: number, character: number): Promise<unknown> {
    await this.openFile(absPath, 150);
    return this.request("textDocument/completion", {
      textDocument: { uri: this.uriFor(absPath) },
      position: { line: Math.max(0, line - 1), character: Math.max(0, character - 1) },
      context: { triggerKind: 1 },
    });
  }

  async symbols(absPath: string): Promise<unknown> {
    await this.openFile(absPath, 150);
    return this.request("textDocument/documentSymbol", { textDocument: { uri: this.uriFor(absPath) } });
  }

  async references(absPath: string, line: number, character: number, includeDeclaration = false): Promise<unknown> {
    await this.openFile(absPath, 150);
    return this.request("textDocument/references", {
      textDocument: { uri: this.uriFor(absPath) },
      position: { line: Math.max(0, line - 1), character: Math.max(0, character - 1) },
      context: { includeDeclaration },
    });
  }

  close(): void {
    this.socket?.destroy();
    this.socket = null;
    this.ready = false;
  }
}

function severityName(n: number | undefined): Diagnostic["severity"] {
  switch (n) {
    case 1:
      return "error";
    case 2:
      return "warning";
    case 3:
      return "info";
    case 4:
      return "hint";
    default:
      return "info";
  }
}
