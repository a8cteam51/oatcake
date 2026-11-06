import { createRoot } from "react-dom/client";
import { App } from "./App.tsx";
import { SettingsWindow } from "./SettingsView.tsx";

// The Settings window loads the same page with #settings.
createRoot(document.getElementById("root")!).render(location.hash === "#settings" ? <SettingsWindow /> : <App />);
