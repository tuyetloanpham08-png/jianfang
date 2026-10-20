#!/usr/bin/env python3
"""Generate eight small, synthetic regression videos.

Usage: python3 scripts/make_step7_fixtures.py [--output-dir NEW_DIRECTORY]
Default output: Tests/Fixtures/media. All eight targets must be absent.
Requires Python 3 and FFmpeg with libx264/libx265; these are not app dependencies.
"""
import argparse
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "Tests/Fixtures/media"
TAGS = ["-colorspace", "bt709", "-color_primaries", "bt709",
        "-color_trc", "bt709", "-color_range", "tv"]
PARAMS = "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"


def barcode(width, height, rate, seconds):
    band = width // 10
    lum = f"if(mod(floor(N/pow(2,floor(X/{band}))),2),235,16)"
    return ["-f", "lavfi", "-i",
            f"color=c=black:s={width}x{height}:r={rate}:d={seconds},"
            f"format=yuv420p,geq=lum='{lum}':cb=128:cr=128,{PARAMS}"]


def tone(seconds):
    return ["-f", "lavfi", "-i",
            f"sine=frequency=1000:sample_rate=48000:duration={seconds},"
            "aformat=channel_layouts=stereo"]


H264 = ["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-crf", "18", *TAGS]
AAC = ["-c:a", "aac", "-b:a", "160k"]
FIXTURES = {
    "hevc-1440p60.mp4": [
        *barcode(2560, 1440, 60, 4), *tone(4), "-c:v", "libx265",
        "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-x265-params",
        "log-level=error", *TAGS, "-video_track_timescale", "15360",
        *AAC, "-shortest",
    ],
    "av-audio-short-v2.mp4": [
        *barcode(1920, 1080, 30, 4), *tone(3.989), *H264,
        "-video_track_timescale", "15360", *AAC,
    ],
    "av-audio-long-v2.mp4": [
        *barcode(1920, 1080, 30, 4), *tone(4.021), *H264,
        "-video_track_timescale", "15360", *AAC,
    ],
    "av-audio-long-100ms-v2.mp4": [
        *barcode(1920, 1080, 30, 4), *tone(4.1), *H264,
        "-video_track_timescale", "15360", *AAC,
    ],
    "cfr30-tb1000.mp4": [
        *barcode(1920, 1080, 30, 4), *H264, "-video_track_timescale", "1000",
    ],
    "cfr24-tb1000.mp4": [
        *barcode(1920, 1080, 24, 4), *H264, "-video_track_timescale", "1000",
    ],
    "vfr-jitter30-v3.mp4": [
        *barcode(1920, 1080, 30, 4), "-vf",
        "settb=1/15360,setpts='(N/30+mod(N,2)*0.0133)/TB'",
        "-fps_mode", "passthrough", "-enc_time_base:v", "1/15360",
        *H264, "-video_track_timescale", "15360",
    ],
}
COMPATIBLE_NAME = "hevc-1440p60-compatible-v2.mp4"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=pathlib.Path, default=OUT,
                        help="New media directory; default: Tests/Fixtures/media")
    output = parser.parse_args().output_dir.expanduser().resolve()
    names = [*FIXTURES, COMPATIBLE_NAME]
    if output.exists() and not output.is_dir():
        raise SystemExit("Output path is not a directory.")
    existing = [name for name in names
                if (output / name).exists() or (output / name).is_symlink()]
    if existing:
        raise SystemExit("Refusing to replace existing files: " + ", ".join(existing))
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("FFmpeg is required only to generate test media.")
    encoders = subprocess.check_output(
        [ffmpeg, "-hide_banner", "-encoders"], text=True,
        stderr=subprocess.DEVNULL)
    if not all(codec in encoders for codec in ["libx264", "libx265"]):
        raise SystemExit("FFmpeg must include libx264 and libx265.")
    output.mkdir(parents=True, exist_ok=True)
    common = [ffmpeg, "-nostdin", "-hide_banner", "-v", "error", "-n"]
    for name, options in FIXTURES.items():
        subprocess.run([*common, *options, "-map_metadata", "-1",
                        str(output / name)], check=True)
    # Convert only the HEVC input generated above. At 60 -> 30 fps, round=up
    # selects the even source frames, matching the integer sampling rule.
    conversion = [
        "-i", str(output / "hevc-1440p60.mp4"), "-map", "0:v:0",
        "-vf", "fps=30:round=up,"
        "scale=1920:1080:flags=lanczos:in_range=tv:out_range=tv:"
        f"out_color_matrix=bt709,setsar=1,format=yuv420p,{PARAMS}",
        "-frames:v", "120", "-c:v", "libx264", "-profile:v", "high",
        "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p",
        *TAGS, "-video_track_timescale", "15360",
        "-map", "0:a:0", "-af", "aresample=48000,apad", "-t", "4.000000",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        "-map_metadata", "-1", "-movflags", "+faststart",
    ]
    subprocess.run([*common, *conversion, str(output / COMPATIBLE_NAME)], check=True)
    print("Generated eight synthetic regression videos.")


if __name__ == "__main__":
    main()
