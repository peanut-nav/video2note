"""
FunASR 语音转文字模块
用法: python asr.py <audio.wav>
输入: 16kHz mono PCM WAV 文件
输出: 纯文本到 stdout
进度: 输出到 stderr

依赖: pip install funasr
模型: paraformer-zh（通义千问同款引擎，首次自动下载 ~1GB）
"""

import sys
import os


def transcribe(audio_path: str) -> str:
    """
    使用 FunASR paraformer-zh 将语音转为文字。

    - 短音频（<= 3.5 分钟）：一次性处理
    - 长音频（> 3.5 分钟）：自动切分为 3 分钟段，逐段转写后合并
      原因：paraformer 的自注意力机制为 O(n²) 内存复杂度，
      15分钟以上音频会触发 OOM（3.7GB+），分段处理后单段内存可控。
    """
    from funasr import AutoModel

    print("[ASR] 加载模型...", file=sys.stderr)
    model = AutoModel(model="paraformer-zh")

    # 计算音频时长
    import wave
    with wave.open(audio_path, 'rb') as wf:
        duration_sec = wf.getnframes() / wf.getframerate()

    chunk_sec = 180  # 每段 3 分钟
    results = []

    print(f"[ASR] 转写中: {os.path.basename(audio_path)} (~{duration_sec / 60:.0f}分钟)", file=sys.stderr)

    if duration_sec <= chunk_sec + 30:
        # 短音频：一次完成
        full_result = model.generate(input=audio_path, batch_size_s=300)
        if full_result and len(full_result) > 0:
            results.append(full_result[0].get("text", "").strip())
    else:
        # 长音频：分段处理
        import subprocess
        import tempfile

        chunks = int(duration_sec / chunk_sec) + 1
        print(f"[ASR] 分段: {chunks} 段 x {chunk_sec}s", file=sys.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            for i in range(chunks):
                start = i * chunk_sec
                chunk_wav = os.path.join(tmpdir, f"chunk_{i:03d}.wav")
                subprocess.run([
                    "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-i", audio_path,
                    "-ss", str(start), "-t", str(chunk_sec),
                    "-ar", "16000", "-ac", "1", "-acodec", "pcm_s16le",
                    chunk_wav
                ], check=True)

                print(f"[ASR] 处理第 {i + 1}/{chunks} 段...", file=sys.stderr)
                chunk_result = model.generate(input=chunk_wav, batch_size_s=300)
                if chunk_result and len(chunk_result) > 0:
                    text = chunk_result[0].get("text", "").strip()
                    if text:
                        results.append(text)

    text = " ".join(results).strip()
    if not text:
        print("[ASR] WARNING: 转写结果为空", file=sys.stderr)
        return ""

    print(f"[ASR] 转写完成 (~{duration_sec / 60:.1f} 分钟音频, {len(text)} 字符)", file=sys.stderr)
    return text


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python asr.py <audio.wav>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    if not os.path.exists(audio_path):
        print(f"[ASR] ERROR: 文件不存在: {audio_path}", file=sys.stderr)
        sys.exit(1)

    text = transcribe(audio_path)
    if text:
        print(text)
    else:
        sys.exit(1)
