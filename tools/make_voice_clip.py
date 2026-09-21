# -*- coding: utf-8 -*-
"""把一句话合成成「灯塔」语音速记能直接吃的 PCM 音频。

为什么要有这个脚本
------------------
语音识别的验收有个死结：要测「说话 → 出字」就得有人真的说话，
而"人来说一句"没法自动化回归，也谈不上复现。

绕开的办法是**把音频文件当成麦克风数据喂进去** ——
`speechRecognizer.writeAudio()` 本来就是收音频流的设计，
所以只要有一段已知内容的 16k/单声道/16bit PCM，整条链路就能全自动验。

音频用 Windows 自带的 SAPI 离线合成（不外传、无版权问题、每次内容一字不差）。
产物打进 hap 的 rawfile 里，验收时由 VoiceMemo 的 selfTest 读出来喂给引擎。

⚠ 格式必须严格对齐 speechRecognizer.AudioInfo：pcm / 16000 / 单声道 / 16bit。
  SAPI 到 16bit 单声道没问题（SAFT16kHz16BitMono），但它是 **WAVE 容器**，
  头部 44 字节要去掉，喂进引擎的必须是裸 PCM 数据。

用法：python make_voice_clip.py
"""

import os
import sys
import wave

sys.stdout.reconfigure(encoding="utf-8")

import comtypes.client

# ⚠ 这个常量别乱改：SAPI 的 SpeechAudioFormatType 里
#   SAFT16kHz8BitMono = 16、SAFT16kHz16BitMono = 18。
#   把 16 当成 16kHz/16bit 写下去会静默产出 8bit 音频，
#   而 8bit 喂给识别引擎的表现是"不报错、什么都识别不出来"——极难查。
SAFT_16KHZ_16BIT_MONO = 18

PHRASE = "明天下午两点面试，记得带上简历和成绩单"

HERE = os.path.dirname(os.path.abspath(__file__))
# ⚠ 这里必须写绝对路径，别用 "..\..\.." 数上级目录。
#   本项目在 D:\work\workbuddy\lighthouse-guanggu\tools，而工程在 D:\work\DevEcoStudioProject，
#   两者**不是**同一个父目录：少写一级 `..` 就会得到 D:\work\workbuddy\DevEcoStudioProject，
#   makedirs 会老老实实把这个不存在的目录树建出来、把音频写进去，然后脚本报"成功"。
#   实测就这么干过一次 —— hap 打出来 rawfile 是空的，应用报 Invalid relative path，
#   查了半天才发现音频躺在另一个"平行世界"的工程目录里。
LIGHTHOUSE = r"D:\work\DevEcoStudioProject\Lighthouse"
RAW_DIR = os.path.join(LIGHTHOUSE, "entry", "src", "main", "resources", "rawfile")
OUT_WAV = os.path.join(HERE, "_shots", "voice_clip.wav")
OUT_PCM = os.path.join(RAW_DIR, "voice_clip.pcm")


def list_voices():
    sp = comtypes.client.CreateObject("SAPI.SpVoice", dynamic=True)
    vs = sp.GetVoices()
    return [vs.Item(i).GetDescription() for i in range(vs.Count)]


def synth(phrase, out_wav, voice_desc=None):
    sp = comtypes.client.CreateObject("SAPI.SpVoice", dynamic=True)
    if voice_desc:
        vs = sp.GetVoices()
        for i in range(vs.Count):
            if vs.Item(i).GetDescription() == voice_desc:
                sp.Voice = vs.Item(i)
                break
    # 略慢一点，识别引擎对快语速的召回率明显更差
    sp.Rate = -1

    stream = comtypes.client.CreateObject("SAPI.SpFileStream", dynamic=True)
    fmt = comtypes.client.CreateObject("SAPI.SpAudioFormat", dynamic=True)
    fmt.Type = SAFT_16KHZ_16BIT_MONO
    stream.Format = fmt
    # SSFMCreateForWrite = 3
    stream.Open(out_wav, 3, False)
    sp.AudioOutputStream = stream
    sp.Speak(phrase)
    stream.Close()


def to_raw_pcm(wav_path, pcm_path):
    with wave.open(wav_path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        print(f"  WAV 实测：{rate}Hz / {width * 8}bit / {ch}声道 / {n} 帧 / {n / rate:.2f}s")
        if (rate, width, ch) != (16000, 2, 1):
            print(f"  ✗ 格式不对，期望 16000Hz/16bit/单声道 —— 引擎会不接受或识别不出来")
            return False
        data = w.readframes(n)
    with open(pcm_path, "wb") as f:
        f.write(data)
    # 写完立刻回读核对 —— 上一条"路径写错却报成功"的教训：
    # 脚本自己说成功了不算数，磁盘上真的在那儿、字节数对得上才算。
    if not os.path.isfile(pcm_path) or os.path.getsize(pcm_path) != len(data):
        print(f"  ✗ 写出后核对失败：{pcm_path}")
        return False
    print(f"  裸 PCM 写出并核对通过：{pcm_path}（{len(data)} 字节）")
    return True


if __name__ == "__main__":
    voices = list_voices()
    print("宿主机的 SAPI 语音包：")
    for v in voices:
        print("  -", v)

    # 优先挑中文语音；没有中文包就只能放弃这条路
    zh = [v for v in voices if any(k in v for k in ("Chinese", "中文", "Huihui", "Yaoyao", "Kangkang", "Xiaoxiao"))]
    if not zh:
        print("\n✗ 没有中文语音包，合成不出中文测试音频。")
        print("  备选：把 make_voice_clip 的 PHRASE 换成英文（但引擎只支持中文，没意义），")
        print("  或改用「真人对着麦克风说一句」做人工验收。")
        sys.exit(2)

    print(f"\n用「{zh[0]}」合成：{PHRASE}")
    os.makedirs(os.path.dirname(OUT_WAV), exist_ok=True)
    os.makedirs(RAW_DIR, exist_ok=True)
    synth(PHRASE, OUT_WAV, zh[0])
    if to_raw_pcm(OUT_WAV, OUT_PCM):
        print("\n✓ 完成。把 PHRASE 一并记下来，验收脚本要用它做关键词断言：")
        print("  ", PHRASE)
