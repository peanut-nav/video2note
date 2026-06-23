"""
视频到笔记 — 图形界面
用法: python gui.py

tkinter GUI，零额外依赖。包装 video2note.ps1 脚本，通过 JSON Lines
进度文件获取实时进度。
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import subprocess
import json
import os
import sys
import tempfile
import threading
import time


class Video2NoteGUI:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("视频到笔记")
        self.root.geometry("800x600")
        self.root.minsize(700, 500)

        self.proc = None
        self.progress_file = None
        self.progress_offset = 0
        self.is_running = False
        self.note_path = None
        self.last_progress_time = 0
        self.error_log_path = None

        # 设置文件路径
        self.settings_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "gui_settings.json"
        )
        self._load_settings()

        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        # 窗口居中
        self.root.update_idletasks()
        w = self.root.winfo_width()
        h = self.root.winfo_height()
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        x = (sw - w) // 2
        y = (sh - h) // 2
        self.root.geometry(f"+{x}+{y}")

    # ═══════════════════════════════════════════════
    # UI 构建
    # ═══════════════════════════════════════════════
    def _build_ui(self):
        main = ttk.Frame(self.root, padding=12)
        main.pack(fill=tk.BOTH, expand=True)

        # ── 输入区 ────────────────────────────────
        input_frame = ttk.LabelFrame(main, text="输入", padding=8)
        input_frame.pack(fill=tk.X, pady=(0, 8))

        # URL
        ttk.Label(input_frame, text="视频 URL:").grid(
            row=0, column=0, sticky=tk.W, pady=(0, 2), columnspan=3
        )
        self.url_var = tk.StringVar(value=self._last_url)
        self.url_entry = ttk.Entry(input_frame, textvariable=self.url_var, width=80)
        self.url_entry.grid(row=1, column=0, columnspan=3, sticky=tk.EW, pady=(0, 8))

        # Cookies + 输出目录 同行
        ttk.Label(input_frame, text="Cookies (可选):").grid(
            row=2, column=0, sticky=tk.W, pady=(0, 2)
        )
        ttk.Label(input_frame, text="输出目录:").grid(
            row=2, column=1, sticky=tk.W, pady=(0, 2), padx=(16, 0)
        )

        self.cookies_var = tk.StringVar(value=self._last_cookies)
        self.cookies_entry = ttk.Entry(input_frame, textvariable=self.cookies_var, width=32)
        self.cookies_entry.grid(row=3, column=0, sticky=tk.W)
        ttk.Button(input_frame, text="浏览...", command=self._browse_cookies, width=7).grid(
            row=3, column=0, sticky=tk.E, padx=(0, 8)
        )

        self.output_var = tk.StringVar(value=self._last_output)
        self.output_entry = ttk.Entry(input_frame, textvariable=self.output_var, width=32)
        self.output_entry.grid(row=3, column=1, sticky=tk.W, padx=(16, 0))
        ttk.Button(input_frame, text="浏览...", command=self._browse_output, width=7).grid(
            row=3, column=1, sticky=tk.E, padx=(16, 0)
        )

        # 按钮行
        btn_frame = ttk.Frame(input_frame)
        btn_frame.grid(row=4, column=0, columnspan=3, sticky=tk.W, pady=(10, 0))
        self.start_btn = ttk.Button(btn_frame, text="▶ 开始", command=self.start)
        self.start_btn.pack(side=tk.LEFT, padx=(0, 8))
        self.cancel_btn = ttk.Button(btn_frame, text="✕ 取消", command=self.cancel, state=tk.DISABLED)
        self.cancel_btn.pack(side=tk.LEFT)
        self.open_btn = ttk.Button(
            btn_frame, text="📂 打开笔记", command=self._open_note, state=tk.DISABLED
        )
        self.open_btn.pack(side=tk.LEFT, padx=(8, 0))

        input_frame.columnconfigure(0, weight=1)
        input_frame.columnconfigure(1, weight=1)

        # ── 进度区 ────────────────────────────────
        progress_frame = ttk.LabelFrame(main, text="处理进度", padding=4)
        progress_frame.pack(fill=tk.BOTH, expand=True)

        self.progress_text = tk.Text(
            progress_frame,
            height=16,
            wrap=tk.WORD,
            state=tk.DISABLED,
            font=("Microsoft YaHei UI", 9),
        )
        scrollbar = ttk.Scrollbar(
            progress_frame, orient=tk.VERTICAL, command=self.progress_text.yview
        )
        self.progress_text.configure(yscrollcommand=scrollbar.set)
        self.progress_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # 颜色标签
        self.progress_text.tag_configure("step", foreground="#007acc")
        self.progress_text.tag_configure("ok", foreground="#16825d")
        self.progress_text.tag_configure("warn", foreground="#e8a838")
        self.progress_text.tag_configure("err", foreground="#cd3131")
        self.progress_text.tag_configure("info", foreground="#666666")
        self.progress_text.tag_configure("done", foreground="#16825d",
                                          font=("Microsoft YaHei UI", 9, "bold"))
        self.progress_text.tag_configure("banner", foreground="#16825d",
                                          font=("Microsoft YaHei UI", 10, "bold"))

        # ── 状态栏 ────────────────────────────────
        self.status_var = tk.StringVar(value="就绪")
        status_bar = ttk.Label(
            main, textvariable=self.status_var, relief=tk.SUNKEN,
            anchor=tk.W, padding=(6, 2)
        )
        status_bar.pack(fill=tk.X, pady=(8, 0))

        # 绑定 Enter 键
        self.root.bind("<Return>", lambda e: self.start())
        self.root.bind("<Control-Return>", lambda e: self.start())

    # ═══════════════════════════════════════════════
    # 设置持久化
    # ═══════════════════════════════════════════════
    def _load_settings(self):
        """从 gui_settings.json 恢复上次输入"""
        try:
            if os.path.exists(self.settings_path):
                with open(self.settings_path, "r", encoding="utf-8") as f:
                    s = json.load(f)
                self._last_url = s.get("url", "")
                self._last_cookies = s.get("cookies", "")
                self._last_output = s.get("output_dir", ".\\notes")
            else:
                self._last_url = ""
                self._last_cookies = ""
                self._last_output = ".\\notes"
        except Exception:
            self._last_url = ""
            self._last_cookies = ""
            self._last_output = ".\\notes"

    def _save_settings(self):
        """保存当前输入到 gui_settings.json"""
        try:
            s = {
                "url": self.url_var.get().strip(),
                "cookies": self.cookies_var.get().strip(),
                "output_dir": self.output_var.get().strip(),
            }
            with open(self.settings_path, "w", encoding="utf-8") as f:
                json.dump(s, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    # ═══════════════════════════════════════════════
    # 日志与进度
    # ═══════════════════════════════════════════════
    def _log(self, level, message, path=None):
        """向进度区追加一条日志"""
        self.progress_text.configure(state=tk.NORMAL)

        timestamp = time.strftime("%H:%M:%S")
        prefixes = {
            "step": ("▶ ", "step"),
            "ok": ("  ✅ ", "ok"),
            "warn": ("  ⚠️  ", "warn"),
            "err": ("  ❌ ", "err"),
            "info": ("  ℹ ", "info"),
            "done": ("", "done"),
        }
        prefix, tag = prefixes.get(level, ("  ", "info"))
        line = f"{prefix}{message}  [{timestamp}]\n"
        self.progress_text.insert(tk.END, line, tag)

        if level == "done":
            self.note_path = path
            banner = f"\n{'─' * 56}\n  ✅ 完成！笔记已保存到:\n  📝 {path}\n{'─' * 56}\n"
            self.progress_text.insert(tk.END, banner, "banner")

        self.progress_text.see(tk.END)
        self.progress_text.configure(state=tk.DISABLED)
        self.root.update_idletasks()

    # ═══════════════════════════════════════════════
    # 文件选择
    # ═══════════════════════════════════════════════
    def _browse_cookies(self):
        path = filedialog.askopenfilename(
            title="选择 Cookies 文件",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")],
        )
        if path:
            self.cookies_var.set(path)

    def _browse_output(self):
        path = filedialog.askdirectory(title="选择输出目录")
        if path:
            self.output_var.set(path)

    # ═══════════════════════════════════════════════
    # 启动 / 取消
    # ═══════════════════════════════════════════════
    def start(self):
        url = self.url_var.get().strip()
        if not url:
            messagebox.showwarning("输入错误", "请输入视频 URL", parent=self.root)
            return
        if self.is_running:
            return

        self.is_running = True
        self.note_path = None
        self._save_settings()
        self._set_ui_state("running")

        # 清空进度区
        self.progress_text.configure(state=tk.NORMAL)
        self.progress_text.delete(1.0, tk.END)
        self.progress_text.configure(state=tk.DISABLED)

        self._log("step", "启动处理...")
        self.status_var.set("处理中...")

        # 创建临时进度文件
        fd, self.progress_file = tempfile.mkstemp(
            suffix=".jsonl", prefix="video2note_progress_"
        )
        os.close(fd)
        self.progress_offset = 0
        self.last_progress_time = time.time()

        # 脚本路径
        script_dir = os.path.dirname(os.path.abspath(__file__))
        ps1_path = os.path.join(script_dir, "video2note.ps1")

        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ps1_path,
            "-Url", url,
            "-OutputDir", self.output_var.get().strip(),
            "-ProgressFile", self.progress_file,
        ]

        cookies = self.cookies_var.get().strip()
        if cookies:
            cmd.extend(["-Cookies", cookies])

        # 创建临时文件捕获脚本输出（出错时用于诊断）
        fd_err, self.error_log_path = tempfile.mkstemp(
            suffix=".txt", prefix="video2note_error_"
        )
        os.close(fd_err)

        # 使用 PIPE + 线程可靠捕获所有输出
        def _drain(pipe, path):
            """后台线程：读取管道内容写入文件"""
            try:
                with open(path, "a", encoding="utf-8") as ef:
                    for line in iter(pipe.readline, ""):
                        ef.write(line)
                        ef.flush()
            except Exception:
                pass
            finally:
                try:
                    pipe.close()
                except Exception:
                    pass

        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=script_dir,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except Exception as e:
            self._log("err", f"启动失败: {e}")
            self._finalize("failed")
            return

        # 启动后台线程读取 stdout/stderr
        self._t_stdout = threading.Thread(
            target=_drain, args=(self.proc.stdout, self.error_log_path), daemon=True
        )
        self._t_stderr = threading.Thread(
            target=_drain, args=(self.proc.stderr, self.error_log_path), daemon=True
        )
        self._t_stdout.start()
        self._t_stderr.start()

        # 开始轮询进度文件
        self.root.after(200, self._poll)

    def cancel(self):
        if not self.is_running:
            return
        if self.proc and self.proc.poll() is None:
            self._log("warn", "正在取消...")
            try:
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(self.proc.pid)],
                    capture_output=True,
                    timeout=5,
                )
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self._finalize("cancelled")

    # ═══════════════════════════════════════════════
    # 轮询
    # ═══════════════════════════════════════════════
    def _poll(self):
        if self.proc is None:
            return

        # 读取新的进度行（可能被 PowerShell Add-Content 临时锁定）
        if self.progress_file and os.path.exists(self.progress_file):
            try:
                with open(self.progress_file, "r", encoding="utf-8") as f:
                    f.seek(self.progress_offset)
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entry = json.loads(line)
                            self._log(
                                entry.get("level", "info"),
                                entry.get("message", ""),
                                entry.get("path"),
                            )
                            self.last_progress_time = time.time()
                        except json.JSONDecodeError:
                            pass
                    self.progress_offset = f.tell()
            except (PermissionError, OSError):
                pass  # 文件被锁定，下次轮询再读

        # 检查进程状态
        ret = self.proc.poll()
        if ret is None:
            # 超时检测：超过 120 秒无进度则警告
            if time.time() - self.last_progress_time > 120:
                self._log("warn", "超过 2 分钟无新进度，可能卡住了（可手动取消）")
                self.last_progress_time = time.time()  # 避免重复警告
            self.root.after(200, self._poll)
        else:
            if ret == 0:
                self._finalize("success")
            else:
                self._log("err", f"处理异常终止 (退出码: {ret})")
                self._finalize("failed")

    # ═══════════════════════════════════════════════
    # 结束处理
    # ═══════════════════════════════════════════════
    def _finalize(self, status):
        self.is_running = False
        self.proc = None
        self._set_ui_state(status)

        # 等待后台读取线程结束（最多 3 秒）
        for t in [getattr(self, "_t_stdout", None), getattr(self, "_t_stderr", None)]:
            if t and t.is_alive():
                t.join(timeout=3)

        if status == "success":
            self.status_var.set("完成 — 笔记已保存")
        elif status == "cancelled":
            self.status_var.set("已取消")
        elif status == "failed":
            # 读取脚本输出用于诊断
            if self.error_log_path and os.path.exists(self.error_log_path):
                try:
                    with open(self.error_log_path, "r", encoding="utf-8") as f:
                        err_output = f.read().strip()
                    if err_output:
                        # 截取最后 2000 字符
                        if len(err_output) > 2000:
                            err_output = "...(截断)\n" + err_output[-2000:]
                        self._log("err", f"脚本输出:\n{err_output}")
                except Exception:
                    pass
            if "完成" not in self.status_var.get():
                self.status_var.set("失败 — 请查看上方错误信息")

        # 清理进度文件
        if self.progress_file and os.path.exists(self.progress_file):
            try:
                os.remove(self.progress_file)
            except OSError:
                pass
        self.progress_file = None
        self.progress_offset = 0

        # 清理错误日志
        if self.error_log_path and os.path.exists(self.error_log_path):
            try:
                os.remove(self.error_log_path)
            except OSError:
                pass
        self.error_log_path = None

    def _set_ui_state(self, state):
        """切换 UI 控件可用状态"""
        if state == "running":
            self.start_btn.configure(state=tk.DISABLED)
            self.cancel_btn.configure(state=tk.NORMAL)
            self.open_btn.configure(state=tk.DISABLED)
            self.url_entry.configure(state=tk.DISABLED)
            self.cookies_entry.configure(state=tk.DISABLED)
            self.output_entry.configure(state=tk.DISABLED)
        else:
            self.start_btn.configure(state=tk.NORMAL)
            self.cancel_btn.configure(state=tk.DISABLED)
            self.url_entry.configure(state=tk.NORMAL)
            self.cookies_entry.configure(state=tk.NORMAL)
            self.output_entry.configure(state=tk.NORMAL)
            if state == "success" and self.note_path:
                self.open_btn.configure(state=tk.NORMAL)
            else:
                self.open_btn.configure(state=tk.DISABLED)

    # ═══════════════════════════════════════════════
    # 打开笔记 / 关闭窗口
    # ═══════════════════════════════════════════════
    def _open_note(self):
        if self.note_path and os.path.exists(self.note_path):
            os.startfile(self.note_path)
        else:
            messagebox.showwarning(
                "文件不存在",
                f"笔记文件已不存在:\n{self.note_path}",
                parent=self.root,
            )

    def _on_close(self):
        if self.is_running:
            if messagebox.askokcancel(
                "确认", "任务正在运行中，确定要退出吗？", parent=self.root
            ):
                self.cancel()
                self.root.destroy()
        else:
            self.root.destroy()

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    app = Video2NoteGUI()
    app.run()
