import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { GodotVersion } from "./godot.js";

export interface ClassMember {
  name: string;
  args?: string[];
  returns?: string;
  brief?: string;
  description?: string;
  default?: string;
  isStatic?: boolean;
  isVirtual?: boolean;
  enum?: string;
  value?: number;
}

export interface ClassDoc {
  name: string;
  inherits: string | null;
  brief: string;
  description: string;
  isRefCounted: boolean;
  inheritsRefCounted: boolean;
  apiType: string;
  briefDescription: string;
  methods: Record<string, ClassMember>;
  properties: Record<string, ClassMember>;
  signals: Record<string, ClassMember>;
  enums: Record<string, string[]>;
  constants: Record<string, ClassMember>;
}

export interface ApiIndexMeta {
  version: GodotVersion;
  builtAt: string;
  classes: number;
  methods: number;
  properties: number;
  file: string;
}

/**
 * Индекс API движка на основе `godot --dump-extension-api-with-docs`.
 * Хранится в кэше пользователя и переиспользуется между запусками.
 * Структурные данные (сигнатуры, перечисления) всегда доступны через ClassDB хоста,
 * индекс даёт документацию и быстрый поиск по всему API.
 */
export class ApiIndex {
  private classes = new Map<string, ClassDoc>();
  private meta: ApiIndexMeta | null = null;
  private loading: Promise<boolean> | null = null;

  constructor(
    private cacheDir: string,
    private runDump: (args: string[], cwd: string) => Promise<{ code: number; stdout: string; stderr: string }>,
  ) {}

  getMeta(): ApiIndexMeta | null {
    return this.meta;
  }

  isLoaded(): boolean {
    return this.meta !== null;
  }

  private cacheFile(version: GodotVersion): string {
    return path.join(this.cacheDir, version.full.replace(/[^\w.-]+/g, "_"), "extension_api.json");
  }

  /** Загружает индекс из кэша или собирает его заново. */
  async ensure(version: GodotVersion, force = false): Promise<boolean> {
    if (this.meta && !force) return true;
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const file = this.cacheFile(version);
      if (!force && existsSync(file)) {
        try {
          await this.parse(file, version);
          return true;
        } catch (err) {
          // Повреждённый кэш — пересобираем.
          process.stderr.write(`[bismuth-mcp-godot] не удалось прочитать кэш API (${String(err)}), пересобираю\n`);
        }
      }
      const ok = await this.build(version, file);
      if (ok) {
        try {
          await this.parse(file, version);
          return true;
        } catch (err) {
          process.stderr.write(`[bismuth-mcp-godot] индекс API собран, но не разобран: ${String(err)}\n`);
          return false;
        }
      }
      return false;
    })();
    try {
      return await this.loading;
    } finally {
      this.loading = null;
    }
  }

  private async build(_version: GodotVersion, file: string): Promise<boolean> {
    const dir = path.dirname(file);
    mkdirSync(dir, { recursive: true });
    const tmp = path.join(dir, "extension_api.json.tmp");
    const started = Date.now();
    const res = await this.runDump(
      ["--headless", "--dump-extension-api-with-docs", "--path", dir],
      dir,
    ).catch(() => ({ code: -1, stdout: "", stderr: "" }));
    if (res.code !== 0) {
      // Некоторые сборки пишут файл только в текущий каталог.
      if (!existsSync(tmp)) {
        process.stderr.write(`[bismuth-mcp-godot] не удалось собрать API (код ${res.code}): ${res.stderr.slice(-500)}\n`);
        return false;
      }
    }
    const produced = existsSync(tmp) ? tmp : file;
    if (!existsSync(produced)) {
      process.stderr.write(`[bismuth-mcp-godot] godot не создал extension_api.json в ${dir}\n`);
      return false;
    }
    process.stderr.write(
      `[bismuth-mcp-godot] индекс API собран за ${Math.round((Date.now() - started) / 1000)} c → ${produced}\n`,
    );
    return true;
  }

  private async parse(file: string, version: GodotVersion): Promise<void> {
    const raw = JSON.parse(readFileSync(file, "utf8")) as RawApi;
    const map = new Map<string, ClassDoc>();
    let methods = 0;
    let properties = 0;
    for (const c of raw.classes ?? []) {
      const doc: ClassDoc = {
        name: c.name,
        inherits: c.inherits ?? null,
        brief: c.brief ?? "",
        description: c.description ?? "",
        isRefCounted: c.is_refcounted ?? false,
        inheritsRefCounted: c.inherits_refcounted ?? false,
        apiType: c.api_type ?? "core",
        briefDescription: c.brief_description ?? "",
        methods: {},
        properties: {},
        signals: {},
        enums: {},
        constants: {},
      };
      for (const m of c.methods ?? []) {
        doc.methods[m.name] = {
          name: m.name,
          args: (m.arguments ?? []).map((a) => `${a.type} ${a.name}`),
          returns: m.return_value ? formatReturn(m.return_value) : undefined,
          brief: m.brief ?? "",
          description: m.description ?? "",
          isStatic: m.is_static ?? false,
          isVirtual: m.is_virtual ?? false,
        };
        methods += 1;
      }
      for (const p of c.properties ?? []) {
        doc.properties[p.name] = {
          name: p.name,
          brief: p.brief ?? "",
          default: p.default_value,
          enum: p.enum,
        };
        properties += 1;
      }
      for (const s of c.signals ?? []) {
        doc.signals[s.name] = {
          name: s.name,
          args: (s.arguments ?? []).map((a) => `${a.type} ${a.name}`),
          brief: s.brief ?? "",
          description: s.description ?? "",
        };
      }
      // В extension_api.json enums — массив объектов {name, is_bitfield, values:[{name,value}]}.
      for (const e of c.enums ?? []) {
        doc.enums[e.name] = (e.values ?? []).map((v) => v.name);
      }
      for (const k of c.constants ?? []) {
        doc.constants[k.name] = { name: k.name, value: k.value, brief: k.brief ?? "" };
      }
      map.set(c.name, doc);
    }
    this.classes = map;
    this.meta = {
      version,
      builtAt: new Date().toISOString(),
      classes: map.size,
      methods,
      properties,
      file,
    };
  }

  has(name: string): boolean {
    return this.classes.has(name);
  }

  get(name: string): ClassDoc | undefined {
    return this.classes.get(name);
  }

  /** Документация класса вместе с унаследованными (по цепочке наследования). */
  describe(name: string, includeInherited = true): ClassDoc | null {
    const own = this.classes.get(name);
    if (!own) return null;
    if (!includeInherited) return own;
    const merged: ClassDoc = {
      ...own,
      methods: { ...own.methods },
      properties: { ...own.properties },
      signals: { ...own.signals },
      enums: { ...own.enums },
      constants: { ...own.constants },
    };
    let parent = own.inherits;
    const seen = new Set<string>();
    while (parent && !seen.has(parent)) {
      seen.add(parent);
      const p = this.classes.get(parent);
      if (!p) break;
      for (const [k, v] of Object.entries(p.methods)) if (!(k in merged.methods)) merged.methods[k] = v;
      for (const [k, v] of Object.entries(p.properties)) if (!(k in merged.properties)) merged.properties[k] = v;
      for (const [k, v] of Object.entries(p.signals)) if (!(k in merged.signals)) merged.signals[k] = v;
      for (const [k, v] of Object.entries(p.enums)) if (!(k in merged.enums)) merged.enums[k] = v;
      for (const [k, v] of Object.entries(p.constants)) if (!(k in merged.constants)) merged.constants[k] = v;
      parent = p.inherits;
    }
    return merged;
  }

  /** Поиск по классам и членам API. */
  search(query: string, limit = 40, kinds: string[] = ["class", "method", "property", "signal", "enum"]): {
    results: Array<{ class: string; kind: string; name: string; detail?: string }>;
    total: number;
  } {
    const needle = query.toLowerCase();
    const results: Array<{ class: string; kind: string; name: string; detail?: string; score: number }> = [];
    for (const cls of this.classes.values()) {
      if (kinds.includes("class") && cls.name.toLowerCase().includes(needle)) {
        results.push({ class: cls.name, kind: "class", name: cls.name, detail: cls.inherits ?? "", score: scoreOf(cls.name, needle) });
      }
      if (results.length > limit * 20) break;
      for (const [kind, bag] of [
        ["method", cls.methods],
        ["property", cls.properties],
        ["signal", cls.signals],
        ["constant", cls.constants],
      ] as const) {
        if (!kinds.includes(kind)) continue;
        for (const key of Object.keys(bag)) {
          if (key.toLowerCase().includes(needle)) {
            results.push({ class: cls.name, kind, name: key, detail: (bag as Record<string, ClassMember>)[key]?.brief ?? "", score: scoreOf(key, needle) + 1 });
            if (results.length > limit * 20) break;
          }
        }
      }
      if (kinds.includes("enum")) {
        for (const [enumName, values] of Object.entries(cls.enums ?? {})) {
          const list = Array.isArray(values) ? values : [];
          if (enumName.toLowerCase().includes(needle)) {
            results.push({ class: cls.name, kind: "enum", name: enumName, detail: list.join(", "), score: scoreOf(enumName, needle) + 1 });
          }
          for (const v of list) {
            if (String(v).toLowerCase().includes(needle)) {
              results.push({ class: cls.name, kind: "enum_value", name: `${enumName}.${v}`, detail: cls.name, score: scoreOf(String(v), needle) + 2 });
            }
          }
        }
      }
    }
    results.sort((a, b) => a.score - b.score || a.class.localeCompare(b.class));
    return {
      results: results.slice(0, limit).map(({ score: _score, ...rest }) => rest),
      total: results.length,
    };
  }

  fileSize(): number {
    if (!this.meta) return -1;
    try {
      return statSync(this.meta.file).size;
    } catch {
      return -1;
    }
  }
}

function scoreOf(name: string, needle: string): number {
  const n = name.toLowerCase();
  if (n === needle) return 0;
  if (n.startsWith(needle)) return 1;
  return 2;
}

function formatReturn(r: { type: string; class_name?: string }): string {
  return r.class_name ? `${r.type}<${r.class_name}>` : r.type;
}

interface RawApi {
  classes?: Array<{
    name: string;
    inherits?: string;
    brief?: string;
    description?: string;
    is_refcounted?: boolean;
    inherits_refcounted?: boolean;
    api_type?: string;
    brief_description?: string;
    methods?: Array<{
      name: string;
      is_static?: boolean;
      is_const?: boolean;
      is_vararg?: boolean;
      is_virtual?: boolean;
      brief?: string;
      description?: string;
      return_value?: { type: string; class_name?: string };
      arguments?: Array<{ name: string; type: string }>;
    }>;
    properties?: Array<{ name: string; type: string; brief?: string; default_value?: string; enum?: string }>;
    signals?: Array<{ name: string; brief?: string; description?: string; arguments?: Array<{ name: string; type: string }> }>;
    enums?: Array<{ name: string; is_bitfield?: boolean; values?: Array<{ name: string; value: number }> }>;
    constants?: Array<{ name: string; value: number; brief?: string }>;
  }>;
}
