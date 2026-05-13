import type { Store, StoreRequest, StoreResponse, Theme } from "./types.js";

const HOST = "com.ko.bm_store";

function call<T>(req: StoreRequest): Promise<T> {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST, req, (raw: unknown) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message ?? "native messaging error"));
        return;
      }
      const res = raw as StoreResponse | undefined;
      if (!res) {
        reject(new Error("empty native messaging response"));
        return;
      }
      if (!res.ok) {
        reject(new Error(res.error));
        return;
      }
      resolve(res.data as T);
    });
  });
}

export const loadStore = () => call<Store>({ op: "load" });
export const addTab = (tab: Store["tabs"][number]) =>
  call<Store>({ op: "add_tab", tab });
export const removeTab = (id: string) => call<Store>({ op: "remove_tab", id });
export const loadTheme = () => call<Theme>({ op: "get_theme" });
