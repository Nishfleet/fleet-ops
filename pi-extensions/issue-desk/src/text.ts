export const firstLine = (value: string): string =>
  value
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line !== "") ?? "";

export const singleLine = (value: string): string => value.replace(/\s+/g, " ").trim();

export const clip = (value: string, max: number): string =>
  value.length <= max ? value : `${value.slice(0, Math.max(0, max - 1))}…`;

export const plain = (value: string): string =>
  value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "");
