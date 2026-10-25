# Roadmap

## Planned: merge AAX Audio Converter into the app

[AAX Audio Converter](https://github.com/audiamus/AaxAudioConverter) is Windows-only. Book Lib Connect already produces a plain `.m4b` with chapters, so the converter is only needed for what it adds on top. The idea is to port that functionality into this app, so the "Export as .aax" hand-off is no longer necessary:

- MP3 output (re-encode, selectable bitrate / mono-stereo)
- Split a book into one file per chapter (m4b or mp3)
- Output folder structure and file naming templates, tagging
- Possibly a "convert after download" step in the main window next to Download / Decrypt / Export

Ideas for implementation: use AVFoundation / AudioToolbox for AAC decode and LAME-free MP3 alternatives where licensing allows, or bundle ffmpeg; reuse the chapter data already stored per book. Source for behaviour reference: the AaxAudioConverter repository above (GPLv3, same licence as this project).

Status: not started.
