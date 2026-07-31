# Changelog

All notable changes to the Harvey project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-07-31

### Added
* Native MLX inference pipeline running `Meta-Llama-3-8B-Instruct-4bit` locally.
* Local RAG architecture using Chroma DB and `nomic-embed-text-v1.5` embeddings.
* Incremental ingestion script (`ingest.py`) with modification timestamp tracking via `ingested_manifest.json`.
* Offline document downloader (`fetch_docs.py`) supporting developer docs.
* Local Kokoro ONNX Text-to-Speech integration (`kokoro-v1.0.onnx`).
* Native SwiftUI macOS desktop client (`HarveyMacApp`) featuring:
  * Multi-session chat management with persistence.
  * Real-time hardware metrics monitoring (CPU, RAM, Thermal state).
  * Audio call mode with live voice transcription and speech output.
  * Export options to Markdown and PDF.
* A better personality for Harvey, although his memory is still not good enough.

## [1.0.0] - 2026-07-30

### First stable version of Harvey (First commit)

First commit with `harvey.py`, `fetch_docs.py` and `ingest.py`, entirely on a browser.

## [0.0.1] - 2026-07-29

### Conception

Harvey is born at 10:54 PM, after saying his first words. Scrambled, a bit confused, but with a lot of potential. No memories or skills whatsoever. Happy Birthday, Harvey!

## [0.0.0] - 2026-07-29

### Preconception

I had the idea of creating an AI that was fast, local, reliable and secure at 9:05 PM (UTC -03:00), after going to the movies. I already had his name: Harvey. So I immediately drove home and developed `harvey.py`, a sketch of his soon-to-be brain.