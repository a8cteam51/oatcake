// Runs the analysis in an Electron utility process so the native models don't block the app.
import { analyse } from "../core/process.ts";

const post = (message: object) => process.parentPort.postMessage(message);

analyse(process.argv[2], post).then(
  () => {
    post({ done: true });
    process.exit(0);
  },
  (error: Error) => {
    post({ error: error.message });
    process.exit(1);
  },
);
