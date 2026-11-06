import type { Api } from "../shared/api.ts";

declare global {
  interface Window {
    api: Api;
  }
}

export const api = window.api;
export type * from "../shared/api.ts";
