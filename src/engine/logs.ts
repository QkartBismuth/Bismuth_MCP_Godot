export interface LogEntry {
  seq: number;
  ts: number;
  stream: "stdout" | "stderr" | "mcp";
  level: "debug" | "info" | "warning" | "error" | "success";
  text: string;
  /** Разобранный фрейм стека GDScript, если строка похожа на трассировку. */
  frame?: { func: string; file: string; line: number };
}

/**
 * Кольцевой буфер логов процесса Godot с разбором ошибок и стек-трейсов.
 * Пишет в stderr только при verbose, чтобы не засорять протокол MCP.
 */
export class LogBuffer {
  private lines: LogEntry[] = [];
  private seq = 0;
  private partial = { stdout: "", stderr: "" };

  constructor(
    private maxLines: number,
    private verbose: boolean,
  ) {}

  push(stream: LogEntry["stream"], chunk: string): void {
    const buf = this.partial[stream as "stdout" | "stderr"] + chunk;
    const parts = buf.split("\n");
    this.partial[stream as "stdout" | "stderr"] = parts.pop() ?? "";
    for (const raw of parts) this.pushLine(stream, raw);
  }

  flush(): void {
    for (const stream of ["stdout", "stderr"] as const) {
      if (this.partial[stream]) {
        this.pushLine(stream, this.partial[stream]);
        this.partial[stream] = "";
      }
    }
  }

  private pushLine(stream: LogEntry["stream"], text: string): void {
    const entry: LogEntry = {
      seq: this.seq++,
      ts: Date.now(),
      stream,
      level: classify(text),
      text,
    };
    const frame = parseFrame(text);
    if (frame) entry.frame = frame;
    this.lines.push(entry);
    if (this.lines.length > this.maxLines) {
      this.lines.splice(0, this.lines.length - this.maxLines);
    }
    if (this.verbose) {
      process.stderr.write(`[godot:${stream}] ${text}\n`);
    }
  }

  /** Событие от MCP-хоста/редактора, не связанное с stdout. */
  pushEvent(text: string, level: LogEntry["level"] = "info"): void {
    this.lines.push({ seq: this.seq++, ts: Date.now(), stream: "mcp", level, text });
    if (this.lines.length > this.maxLines) {
      this.lines.splice(0, this.lines.length - this.maxLines);
    }
    if (this.verbose) process.stderr.write(`[mcp] ${text}\n`);
  }

  list(opts: { since?: number; limit?: number; level?: LogEntry["level"]; errorsOnly?: boolean } = {}): {
    entries: LogEntry[];
    cursor: number;
    truncated: boolean;
  } {
    const since = opts.since ?? 0;
    let entries = this.lines.filter((l) => l.seq >= since);
    if (opts.errorsOnly) entries = entries.filter((l) => l.level === "error" || l.level === "warning");
    else if (opts.level) entries = entries.filter((l) => l.level === opts.level);
    const limit = Math.min(opts.limit ?? 200, this.maxLines);
    const truncated = entries.length > limit;
    const cursor = this.seq;
    return { entries: entries.slice(-limit), cursor, truncated };
  }

  clear(): void {
    this.lines = [];
    this.partial = { stdout: "", stderr: "" };
  }
}

function classify(text: string): LogEntry["level"] {
  if (/SCRIPT ERROR|USER ERROR|^ERROR:|Parse Error|Failed to load|Cannot open|Condition \"/.test(text)) {
    return "error";
  }
  if (/^WARNING:|WARNING:|Attempt to call|Invalid (get|set|call)|Object of type/.test(text)) {
    return "warning";
  }
  if (/^\s*at:\s/.test(text)) return "error";
  return "info";
}

const FRAME_RE = /^\s*at:\s+(.+?)\s+\((.+?):(\d+)\)\s*$/;

export function parseFrame(text: string): LogEntry["frame"] | undefined {
  const m = FRAME_RE.exec(text);
  if (!m) return undefined;
  return { func: m[1] ?? "", file: m[2] ?? "", line: Number.parseInt(m[3] ?? "0", 10) };
}

/** Группирует трассировки: сообщение + последующие строки "at: ...". */
export function groupTracebacks(entries: LogEntry[]): Array<{
  message: string;
  level: LogEntry["level"];
  file?: string;
  line?: number;
  frames: LogEntry["frame"][];
}> {
  const out: Array<{
    message: string;
    level: LogEntry["level"];
    file?: string;
    line?: number;
    frames: LogEntry["frame"][];
  }> = [];
  for (const entry of entries) {
    if (entry.frame) {
      if (out.length > 0) out[out.length - 1]?.frames.push(entry.frame);
      continue;
    }
    if (entry.level !== "error" && entry.level !== "warning") continue;
    out.push({ message: entry.text, level: entry.level, frames: [] });
  }
  return out;
}
