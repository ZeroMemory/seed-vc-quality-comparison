# Seed-VC Quality Comparison

Compare seven Seed-VC v1 and v2 voice conversion settings on the same source and reference. Each run produces a parameter-labeled WAV, log, and TSV entry. Install Seed-VC and its pretrained models separately.

Listen to the [v1 baseline](examples/comparison/v1_01_baseline_steps25_cfg0.7__vc_source_reference_1.0_25_0.7.wav) and [v2 timbre sample](examples/comparison/v2_01_timbre_steps30_int0.0_sim0.7__vc_v2_source_reference_1.0_30_0.7.wav). The [seven CPU samples](examples/comparison/) share a synthetic source and reference. Their [manifest](examples/comparison/manifest.json) records parameters, signal measurements, Whisper recognition, and CAMPPlus scores.

## Dependencies

Use Windows, PowerShell, Python, and `ffprobe`. Prepare a separate [Seed-VC](https://github.com/Plachtaa/seed-vc) checkout at `51383efd921027683c89e5348211d93ff12ac2a8` with its own environment and model weights. `upstream-requirements.txt` records the dependency list.

For CPU inference, run these commands from this toolkit's root to apply the patch to the Seed-VC checkout.

```powershell
$seedRepo = Read-Host 'Path to the Seed-VC checkout'
$patch = Join-Path $PWD.Path 'cpu-dtype.patch'
git -C $seedRepo apply --check --ignore-space-change $patch
git -C $seedRepo apply --ignore-space-change $patch
```

The CPU patch uses float32 for the v1 Whisper tokenizer and v2 AR cache and sets one PyTorch thread. CUDA and MPS retain float16 and their existing thread settings.

For v1, the wrapper defaults to `--fp16 False`. Use `-FP16` with a compatible accelerated runtime.

## Run

From this toolkit's root, run the included synthetic source and reference through the comparison.

```powershell
$seedRepo = Read-Host 'Path to the Seed-VC checkout'
$seedPython = Read-Host 'Path to python.exe in its environment'
$output = Read-Host 'New comparison output directory'
.\Compare-SeedVC.ps1 -Repo $seedRepo -Python $seedPython -Source .\source.example.wav -Target .\reference.example.wav -Output $output
```

Use a new output directory and a separate application checkout because inference runs inside that checkout. For offline runs, prepare every checkpoint and Hugging Face cache entry before setting `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`.

Put custom checkpoints in `<Repo>\checkpoints`. Upstream v1 uses `<Repo>\checkpoints\hf_cache`, and v2 uses `HF_HUB_CACHE`. `model-state.example.json` records the revisions, files, and hashes for the CPU example.

| ID | Version | Steps | CFG / intelligibility | Similarity | Style conversion |
| --- | --- | ---: | ---: | ---: | --- |
| v1_01_baseline | v1 | 25 | 0.7 | — | — |
| v1_02_quality | v1 | 50 | 0.7 | — | — |
| v1_03_soft | v1 | 35 | 0.5 | — | — |
| v1_04_strong | v1 | 35 | 0.9 | — | — |
| v2_01_timbre | v2 | 30 | 0.0 | 0.7 | false |
| v2_02_timbre | v2 | 50 | 0.0 | 0.85 | false |
| v2_03_style | v2 | 50 | 0.3 | 0.85 | true |

All modes use length adjustment 1.0. To run the 50-step v1 configuration alone, add `-Variant v1_02_quality_steps50_cfg0.7`. The full IDs are listed in `Compare-SeedVC.ps1` and appear in output filenames.

To generate longer source/reference files, run this from the toolkit's root:

```powershell
$audioOutput = Read-Host 'New directory for source and reference audio'
.\New-NeutralAudio.ps1 -OutputDirectory $audioOutput
```

The generator uses installed English Windows SAPI voices.
