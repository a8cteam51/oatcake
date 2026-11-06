// The design's line icons (16×16 grid).
import type { CSSProperties } from "react";

type P = { size?: number; style?: CSSProperties; className?: string };
const line = (paths: React.ReactNode, width = 1.5) =>
  function Icon({ size = 14, style, className }: P) {
    return (
      <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" className={className}
        style={{ strokeWidth: width, strokeLinecap: "round", strokeLinejoin: "round", flex: "none", ...style }}>
        {paths}
      </svg>
    );
  };

export const FolderIcon = line(<path d="M1.75 4.25c0-.83.67-1.5 1.5-1.5h3l1.5 1.5h5c.83 0 1.5.67 1.5 1.5v6.5c0 .83-.67 1.5-1.5 1.5h-9.5c-.83 0-1.5-.67-1.5-1.5z" />, 1.3);
export const NewFolderIcon = line(<><path d="M1.75 4.25c0-.83.67-1.5 1.5-1.5h3l1.5 1.5h5c.83 0 1.5.67 1.5 1.5v6.5c0 .83-.67 1.5-1.5 1.5h-9.5c-.83 0-1.5-.67-1.5-1.5z" /><path d="M8 7.25v4M6 9.25h4" /></>, 1.4);
export const ChevronIcon = line(<path d="M6 3.5l4.5 4.5L6 12.5" />, 2);
export const ChevronDownIcon = line(<path d="M3.5 6l4.5 4.5L12.5 6" />, 2);
export const RefreshIcon = line(<path d="M13 8a5 5 0 11-1.46-3.54M13 2.5v3h-3" />, 1.7);
export const WarningIcon = line(<><path d="M8 2.25l6.25 11H1.75z" /><path d="M8 6.5v3M8 11.6v.01" /></>);
export const SettingsIcon = line(<><path d="M2.5 5h6M12 5h1.5M2.5 11h1.5M7.5 11h6" /><circle cx="10.25" cy="5" r="1.75" /><circle cx="5.75" cy="11" r="1.75" /></>);
export const FinderIcon = line(<path d="M6.5 3H3.5A1.5 1.5 0 002 4.5v8A1.5 1.5 0 003.5 14h8a1.5 1.5 0 001.5-1.5v-3M9.5 2H14v4.5M14 2L7.5 8.5" />);
export const FileIcon = line(<><path d="M4 1.75h5l3 3v9.5H4z" /><path d="M9 1.75v3h3M6 8h4M6 10.5h4" /></>, 1.4);
export const CheckIcon = line(<path d="M3.5 8.5l3 3 6-7" />, 2.5);
export const CalendarIcon = line(<><rect x="2.5" y="3.5" width="11" height="10" rx="2" /><path d="M2.5 7h11M5.5 2v3M10.5 2v3" /></>);
export const VideoIcon = line(<><rect x="1.5" y="4.5" width="9" height="7" rx="1.75" /><path d="M10.5 7.25L14.5 5v6l-4-2.25" /></>);
export const MicIcon = line(<><rect x="5.5" y="1.75" width="5" height="8" rx="2.5" /><path d="M3.25 7.75a4.75 4.75 0 009.5 0M8 12.5v1.75" /></>);
export const MergeIcon = line(<path d="M4 2.5v3.5a3 3 0 003 3h5.5M10.5 7l2 2-2 2M4 13.5V10.5" />);
export const PeopleIcon = line(<><circle cx="5.5" cy="5" r="2" /><circle cx="10.5" cy="5" r="2" /><path d="M1.5 13c0-2 1.8-3.5 4-3.5s4 1.5 4 3.5M9.4 9.6a5 5 0 011.1-.1c2.2 0 4 1.5 4 3.5" /></>);
export const KnownIcon = line(<><circle cx="6" cy="5" r="2.5" /><path d="M1.5 13.5c0-2.5 2-4 4.5-4s4.5 1.5 4.5 4M10.5 7.5l1.5 1.5 3-3" /></>);
export const QuoteIcon = line(<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" />);
export const EyeIcon = line(<><path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" /><circle cx="8" cy="8" r="2" /></>, 1.4);
export const EyeOffIcon = line(<><path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" /><circle cx="8" cy="8" r="2" /><path d="M2.5 2.5l11 11" /></>, 1.4);
export const TodosIcon = line(<><rect x="2.5" y="2.5" width="11" height="11" rx="3" /><path d="M5.5 8.25l1.75 1.75 3.25-4" /></>);
export const SendIcon = line(<path d="M8 13V3.5M4 7.5l4-4 4 4" />, 2);

const solid = (paths: React.ReactNode) =>
  function Icon({ size = 12, style }: P) {
    return (
      <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor" style={{ flex: "none", ...style }}>
        {paths}
      </svg>
    );
  };
export const DotIcon = solid(<circle cx="8" cy="8" r="5" />);
export const StopIcon = solid(<rect x="2.5" y="2.5" width="11" height="11" rx="2.5" />);
export const PlayIcon = solid(<path d="M4.5 2.75v10.5a.75.75 0 001.13.65l8.6-5.25a.75.75 0 000-1.3L5.63 2.1a.75.75 0 00-1.13.65z" />);
export const PauseIcon = solid(<><rect x="3.5" y="2.5" width="3.25" height="11" rx="1" /><rect x="9.25" y="2.5" width="3.25" height="11" rx="1" /></>);

/** Up/down chevrons at the right of a select. */
export function SelectChevrons() {
  return (
    <svg width="9" height="12" viewBox="0 0 10 14" fill="none" stroke="currentColor" className="select-chevrons">
      <path d="M2 5l3-3 3 3M2 9l3 3 3-3" />
    </svg>
  );
}
