// Ordering as `LC_ALL=C sort` orders: by bytes, not by UTF-16 code units.

export function byteCompare(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

export function sortBytes(items: readonly string[]): string[] {
  return [...items].sort(byteCompare);
}
