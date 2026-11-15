# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""A window over the converter: python cd_convert_gui.py, or the NeoMillieCD Converter executable.

Add discs or folders, pick the destination (with SD card layout on, the SD card's root), and Convert. The same
engine as cd_convert.py does the work, one disc at a time in a worker thread. The destination and tool paths
are kept in converter.json, in the system's folder for settings. --selftest runs the converter's checks, then
opens and closes the window, and exits non-zero on a failure.
"""
import base64
import json
import os
import pathlib
import platform
import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

sys.dont_write_bytecode = True     # no __pycache__ in tools/
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cdconv  # noqa: E402
import make_logo  # noqa: E402
from cdconv.disc import Cancelled, ConvertError, default_name, find_tool, install_hint  # noqa: E402

TITLE = "NeoMillieCD Converter"
SD_SUBDIR = Path("Assets/ngcd/common")
TOOLS = ("ffmpeg", "chdman")


def config_path(system: str = platform.system()) -> Path:
    home = Path.home()
    if system == "Windows":
        base = Path(os.environ.get("APPDATA") or home / "AppData/Roaming")
    elif system == "Darwin":
        base = home / "Library/Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    return base / "NeoMillieCD" / "converter.json"


def load_config() -> dict:
    try:
        cfg = json.loads(config_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def save_config(cfg: dict) -> None:
    p = config_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
    except OSError:
        pass        # settings are a convenience; a read-only home must not stop a conversion


def sd_dest(dest: Path, sd_layout: bool) -> Path:
    if not sd_layout or [p.lower() for p in dest.parts[-3:]] == [p.lower() for p in SD_SUBDIR.parts]:
        return dest
    return dest / SD_SUBDIR


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(TITLE)
        self.minsize(640, 420)
        # NeoMillieCD's icon instead of Tk's feather; kept on self, as Tk drops an image nothing refers to
        self.icons = [tk.PhotoImage(data=base64.b64encode(make_logo.png(True, n))) for n in (256, 48, 32)]
        self.iconphoto(True, *self.icons)
        self.cfg = load_config()
        self.rows = {}              # iid -> {"source": Path, "name": str}
        self.events = queue.Queue()
        self.cancel = threading.Event()
        self.worker = None
        self.editor = None

        bar = ttk.Frame(self, padding=(8, 8, 8, 0))
        bar.pack(fill="x")
        ttk.Button(bar, text="Add discs…", command=self.add_discs).pack(side="left")
        ttk.Button(bar, text="Add folder…", command=self.add_folder).pack(side="left", padx=4)
        ttk.Button(bar, text="Remove", command=self.remove).pack(side="left")

        frame = ttk.Frame(self, padding=8)
        frame.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(frame, columns=("name", "format", "status"), show="headings", selectmode="extended")
        for col, text, width in (("name", "Name", 220), ("format", "Format", 70), ("status", "Status", 320)):
            self.tree.heading(col, text=text)
            self.tree.column(col, width=width, stretch=col != "format")
        scroll = ttk.Scrollbar(frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.tree.bind("<Double-1>", self.edit_name)

        out = ttk.LabelFrame(self, text="Output", padding=8)
        out.pack(fill="x", padx=8)
        self.dest = tk.StringVar(value=self.cfg.get("dest", ""))
        ttk.Entry(out, textvariable=self.dest).grid(row=0, column=0, sticky="ew")
        ttk.Button(out, text="Browse…", command=self.browse).grid(row=0, column=1, padx=(4, 0))
        self.sd_layout = tk.BooleanVar(value=self.cfg.get("sd_layout", True))
        self.overwrite = tk.BooleanVar(value=False)
        ttk.Checkbutton(out, text="SD card layout (adds Assets/ngcd/common)", variable=self.sd_layout).grid(
            row=1, column=0, sticky="w")
        ttk.Checkbutton(out, text="Overwrite", variable=self.overwrite).grid(row=1, column=1, sticky="w")
        out.columnconfigure(0, weight=1)

        tools = ttk.LabelFrame(self, text="Tools", padding=8)
        tools.pack(fill="x", padx=8, pady=(8, 0))
        self.tool_paths = {}
        self.tool_labels = {}
        for n, name in enumerate(TOOLS):
            self.tool_labels[name] = ttk.Label(tools, wraplength=520, justify="left")
            self.tool_labels[name].grid(row=n, column=0, sticky="w")
            ttk.Button(tools, text="Locate…", command=lambda t=name: self.locate(t)).grid(row=n, column=1, padx=4)
        tools.columnconfigure(0, weight=1)
        self.find_tools()

        run = ttk.Frame(self, padding=8)
        run.pack(fill="x")
        self.disc_bar = ttk.Progressbar(run, maximum=1.0)
        self.total_bar = ttk.Progressbar(run, maximum=1.0)
        ttk.Label(run, text="Disc").grid(row=0, column=0, sticky="w")
        self.disc_bar.grid(row=0, column=1, sticky="ew", padx=4)
        ttk.Label(run, text="Total").grid(row=1, column=0, sticky="w")
        self.total_bar.grid(row=1, column=1, sticky="ew", padx=4, pady=(4, 0))
        self.convert_button = ttk.Button(run, text="Convert", command=self.start)
        self.convert_button.grid(row=0, column=2, rowspan=2, padx=(4, 0))
        self.cancel_button = ttk.Button(run, text="Cancel", command=self.cancel.set, state="disabled")
        self.cancel_button.grid(row=0, column=3, rowspan=2, padx=(4, 0))
        run.columnconfigure(1, weight=1)

        self.protocol("WM_DELETE_WINDOW", self.close)
        self.poll_id = self.after(100, self.poll)

    # Disc list

    def add(self, paths):
        known = {r["source"] for r in self.rows.values()}
        for source in cdconv.find_discs(paths):
            if source in known:
                continue
            try:
                name = default_name(source)
            except ConvertError:
                name = source.stem
            iid = self.tree.insert("", "end", values=(name, source.suffix.lstrip(".").upper(), "pending"))
            self.rows[iid] = {"source": source, "name": name}
            known.add(source)
        self.mark_needs()

    def add_discs(self):
        types = [("Disc images", " ".join(f"*{e}" for e in cdconv.EXTENSIONS)), ("All files", "*")]
        self.add(Path(p) for p in filedialog.askopenfilenames(parent=self, title="Add discs", filetypes=types))

    def add_folder(self):
        folder = filedialog.askdirectory(parent=self, title="Add folder")
        if folder:
            self.add([Path(folder)])

    def remove(self):
        if self.worker:
            return
        for iid in self.tree.selection():
            self.tree.delete(iid)
            del self.rows[iid]

    def edit_name(self, event):
        iid = self.tree.identify_row(event.y)
        if not iid or self.tree.identify_column(event.x) != "#1" or self.worker:
            return
        x, y, w, h = self.tree.bbox(iid, "#1")
        self.editor = ttk.Entry(self.tree)
        self.editor.insert(0, self.rows[iid]["name"])
        self.editor.select_range(0, "end")
        self.editor.place(x=x, y=y, width=w, height=h)
        self.editor.focus_set()

        def done(save):
            if save:
                self.rows[iid]["name"] = self.editor.get()
                self.tree.set(iid, "name", self.editor.get())
                self.tree.set(iid, "status", "pending")
                self.mark_needs()
            self.editor.destroy()
            self.editor = None
        self.editor.bind("<Return>", lambda e: done(True))
        self.editor.bind("<FocusOut>", lambda e: done(True))
        self.editor.bind("<Escape>", lambda e: done(False))

    # Output and tools

    def browse(self):
        folder = filedialog.askdirectory(parent=self, title="Destination", initialdir=self.dest.get() or None)
        if folder:
            self.dest.set(folder)

    def find_tools(self):
        for name in TOOLS:
            path = find_tool(name, self.cfg.get(name))
            self.tool_paths[name] = path
            self.tool_labels[name].configure(text=f"{name}: {path}" if path else f"{name}: missing. {install_hint(name)}")
        self.mark_needs()

    def locate(self, name):
        path = filedialog.askopenfilename(parent=self, title=f"Locate {name}")
        if path:
            self.cfg[name] = path
            self.find_tools()

    def mark_needs(self):
        if not hasattr(self, "tree"):
            return
        for iid, row in self.rows.items():
            missing = sorted(t for t in cdconv.needs(row["source"]) if not self.tool_paths.get(t))
            status = self.tree.set(iid, "status")
            if missing:
                self.tree.set(iid, "status", "needs " + " and ".join(missing))
            elif status.startswith("needs "):
                self.tree.set(iid, "status", "pending")

    # Conversion

    def start(self):
        if self.worker or not self.rows:
            return
        if not self.dest.get():
            self.browse()
            if not self.dest.get():
                return
        self.save()
        self.mark_needs()
        iids = [i for i in self.tree.get_children() if not self.tree.set(i, "status").startswith("needs ")]
        jobs = []
        named = cdconv.assign_names([self.rows[i]["source"] for i in iids], [self.rows[i]["name"] for i in iids])
        for iid, (source, name, error) in zip(iids, named):
            if error:
                self.tree.set(iid, "status", f"error: {error}")
            else:
                self.tree.set(iid, "status", "pending")
                jobs.append((iid, source, name))
        if not jobs:
            return
        self.cancel.clear()
        self.convert_button.configure(state="disabled")
        self.cancel_button.configure(state="normal")
        dest = sd_dest(Path(self.dest.get()), self.sd_layout.get())
        tools = {t: p for t, p in self.tool_paths.items() if p}
        self.worker = threading.Thread(target=self.work, args=(jobs, dest, self.overwrite.get(), tools), daemon=True)
        self.worker.start()

    def work(self, jobs, dest, overwrite, tools):
        """The worker thread: talks to the window only through the queue."""
        for n, (iid, source, name) in enumerate(jobs):
            if self.cancel.is_set():
                self.events.put(("status", iid, "cancelled"))
                continue
            self.events.put(("status", iid, "converting"))

            def progress(f, n=n):
                self.events.put(("progress", f, (n + f) / len(jobs)))
            try:
                r = cdconv.convert(source, dest, name, overwrite=overwrite, tools=tools, progress=progress,
                                   cancel=self.cancel)
                status = "already there" if r.skipped else "done"
            except Cancelled:
                status = "cancelled"
            except ConvertError as e:
                status = f"error: {e}"
            except Exception as e:      # a bug or an OS error must reach the row, not kill the thread silently
                status = f"error: {type(e).__name__}: {e}"
            self.events.put(("status", iid, status))
            self.events.put(("progress", 0.0, (n + 1) / len(jobs)))
        self.events.put(("finished",))

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "status" and self.tree.exists(event[1]):
                    self.tree.set(event[1], "status", event[2])
                elif event[0] == "progress":
                    self.disc_bar["value"], self.total_bar["value"] = event[1], event[2]
                elif event[0] == "finished":
                    self.worker = None
                    self.convert_button.configure(state="normal")
                    self.cancel_button.configure(state="disabled")
        except queue.Empty:
            pass
        self.poll_id = self.after(100, self.poll)

    def save(self):
        self.cfg["dest"] = self.dest.get()
        self.cfg["sd_layout"] = self.sd_layout.get()
        save_config(self.cfg)

    def destroy(self):
        self.after_cancel(self.poll_id)     # else Tk reports the pending poll as an invalid command
        super().destroy()

    def close(self):
        self.cancel.set()
        self.save()
        if self.worker:
            self.worker.join(timeout=10)    # the disc in progress cleans up after itself
        self.destroy()


def main(argv) -> int:
    if argv == ["--selftest"]:
        try:
            from cdconv import selftest
            selftest.run()
            app = App()
            app.update()
            assert [i.width() for i in app.icons] == [256, 48, 32], "the window has no NeoMillieCD icon"
            app.destroy()
        except Exception as e:      # a windowed build has no console: the exit code is what CI reads
            print(f"selftest failed: {type(e).__name__}: {e}")
            return 1
        print("gui ok")
        return 0
    App().mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
