"""生成牛叫提示音 mooo.aiff（0.6 秒，16-bit AIFF）。

v1 = 简单谐波滑音版；v2 = 加 M 音头、颤音、共振峰的更像牛版。
用法：python3 gen_mooo.py
"""
import numpy as np
import soundfile as sf

SAMPLE_RATE = 44100
DURATION = 0.6


def make_v1() -> np.ndarray:
    """基础版：160→90 Hz 滑音 + 4 阶谐波 + 正弦包络。"""
    t = np.linspace(0, DURATION, int(SAMPLE_RATE * DURATION), endpoint=False)
    freq = np.linspace(160, 90, len(t))
    wave = (np.sin(2 * np.pi * freq * t)
            + 0.5 * np.sin(2 * np.pi * 2 * freq * t)
            + 0.3 * np.sin(2 * np.pi * 3 * freq * t)
            + 0.1 * np.sin(2 * np.pi * 4 * freq * t))
    envelope = np.sin(np.pi * t / DURATION) ** 1.5
    return wave * envelope


def _smooth_curve(points, n):
    """控制点 [(秒, 值)] → 线性插值后加窗平滑的长度 n 曲线。"""
    t = np.linspace(0, DURATION, n, endpoint=False)
    times = [p[0] for p in points]
    values = [p[1] for p in points]
    curve = np.interp(t, times, values)
    kernel = np.hanning(257)
    kernel /= kernel.sum()
    return np.convolve(curve, kernel, mode="same")


def make_v2() -> np.ndarray:
    """增强版：m 音头起腔、"ooo" 元音共振峰、颤音与轻微沙哑。"""
    n = int(SAMPLE_RATE * DURATION)
    t = np.linspace(0, DURATION, n, endpoint=False)

    # 音高轮廓：0.58–1.10s，90–98 Hz 平稳低音哞
    # 压缩映射到 0.6s：闷哼 88 → 张口 97 平台 → 微降 93 → 回扬 96 → 收尾落 84
    f0 = _smooth_curve([(0.00, 88), (0.07, 90), (0.10, 97),
                        (0.24, 93), (0.45, 96), (0.60, 84)], n)
    f0 += 2.5 * np.sin(2 * np.pi * 5.5 * t)          # 颤音
    phase = 2 * np.pi * np.cumsum(f0) / SAMPLE_RATE

    # 谐波列（约 1/k^1.2 衰减，比基琴音色更闷更像大型动物）
    wave = np.zeros(n)
    for k in range(1, 7):
        wave += (1.0 / k ** 1.2) * np.sin(k * phase + 0.31 * k)

    # "oo" 元音共振峰：F1≈400 Hz（参考音 4 次谐波 372 Hz 处实测抬升）、F2≈870 Hz
    spec = np.fft.rfft(wave)
    freqs = np.fft.rfftfreq(n, 1 / SAMPLE_RATE)
    formant = (0.35
               + np.exp(-((freqs - 400) / 140) ** 2)
               + 0.6 * np.exp(-((freqs - 870) / 180) ** 2))
    wave = np.fft.irfft(spec * formant, n)

    # 26 Hz 低频幅度抖动 → 声带沙哑感
    wave *= 1 - 0.12 * (0.5 + 0.5 * np.sin(2 * np.pi * 26 * t))

    # 极轻的气声噪声，走同一共振峰滤波
    rng = np.random.default_rng(42)
    breath = rng.normal(0, 1, n)
    breath = np.fft.irfft(np.fft.rfft(breath) * formant, n)
    breath /= np.max(np.abs(breath))
    wave += 0.02 * breath

    # 包络：m 音头压低 → 0.1s 张口放开 → 随后平稳衰减（参考音主段形态）
    envelope = _smooth_curve(
        [(0.000, 0.00), (0.020, 0.28), (0.070, 0.32), (0.100, 0.95),
         (0.130, 1.00), (0.340, 0.85), (0.480, 0.48), (0.575, 0.10),
         (0.600, 0.00)], n)
    return wave * envelope


def finalize_and_write(signal: np.ndarray, filename: str) -> None:
    signal = signal / np.max(np.abs(signal))
    edge = int(0.005 * SAMPLE_RATE)          # 首尾 5 ms 斜坡防爆音
    ramp = np.linspace(0, 1, edge)
    signal[:edge] *= ramp
    signal[-edge:] *= ramp[::-1]
    sf.write(filename, signal, SAMPLE_RATE, format="AIFF", subtype="PCM_16")
    print(f"已生成：{filename}（{len(signal) / SAMPLE_RATE:.2f} 秒）")


if __name__ == "__main__":
    finalize_and_write(make_v1(), "mooo.aiff")
    finalize_and_write(make_v2(), "mooo-v2.aiff")
