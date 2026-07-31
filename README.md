# Harvey: Offline Local AI Assistant

Harvey is a polite, privacy-focused local AI assistant running completely offline on Apple Silicon (optimized for M4 MacBooks). It integrates a local Llama 3 LLM via MLX, a Retrieval-Augmented Generation (RAG) system powered by Chroma DB and local HuggingFace embeddings, and local Kokoro TTS voice synthesis.

The project consists of a Python FastAPI backend (`harvey.py`) and a native macOS SwiftUI frontend client (`HarveyMacApp`).

## System Architecture

* **Backend Framework**: FastAPI & Uvicorn
* **Language Model**: Meta-Llama-3-8B-Instruct-4bit (executed natively on Apple Silicon via `mlx-lm`)
* **Vector Database**: Chroma DB (`./chroma_db`)
* **Text Embeddings**: `nomic-ai/nomic-embed-text-v1.5` (via `langchain-huggingface`)
* **Text-to-Speech (TTS)**: Kokoro ONNX local model (`kokoro-v1.0.onnx`, `voices-v1.0.bin`)
* **Frontend App**: Native macOS SwiftUI App (`HarveyMacApp`)


## Directory Structure

```

harvey/
├── harvey.py                # Main FastAPI backend server and MLX execution engine
├── ingest.py                # RAG document ingestion script with file manifest tracking
├── fetch_docs.py            # Utility script to download local developer documentation
├── data/                    # Raw documentation sources (ignored by Git)
├── memories/                # Long-term user preferences and memory files (ignored by Git)
├── chroma_db/               # Persistent local vector database (ignored by Git)
├── ingested_manifest.json   # Local file modification manifest (ignored by Git)
└── HarveyMacApp/            # Native SwiftUI macOS desktop interface

```


## Prerequisites

* macOS 14.0 or later (Apple Silicon recommended: M1/M2/M3/M4)
* Python 3.10+
* Xcode 15+ (for building the SwiftUI macOS app) or VS Code


## Setup & Installation

### 1. Environment Setup

Create and activate a Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate

```

Install the required Python dependencies:

```bash
pip install --upgrade pip
pip install mlx mlx-lm fastapi uvicorn psutil soundfile kokoro-onnx \
    langchain-huggingface langchain-chroma langchain-community \
    langchain-text-splitters tqdm

```

### 2. Required Local Model Weights

Ensure the local voice synthesis files are present in the project root directory:

* `kokoro-v1.0.onnx`
* `voices-v1.0.bin`

*(Note: These model binaries are ignored by Git due to file size).*

## Initializing RAG Knowledge Base

### Step 1: Download Documentation (Optional)

To download offline copies of developer documentation (MDN, Python, FastAPI, Swift, etc.):
```bash
python fetch_docs.py
```

### Step 2: Ingest Documents into Vector Database

To process text chunks and populate Chroma DB:

```bash
python ingest.py
```

`ingest.py` tracks file timestamps in `ingested_manifest.json` to process only new or modified files on subsequent runs.


## Running the Application

### 1. Start the FastAPI Backend Server

You can start the backend manually using Python:

```bash
python harvey.py
```

The server runs locally at `http://127.0.0.1:8000`.

### 2. Launch the macOS Desktop App

Open the `HarveyMacApp` project in Xcode:

1. Open Xcode and select the `HarveyMacApp` directory.
2. Build and run the project (`Cmd + R`).

*Note: The macOS application will automatically spawn and manage the `harvey.py` backend process upon launch if it is not already running.*

## API Endpoints

* `GET /api/metrics`: Returns system RAM, CPU usage, process memory, and Mac thermal state.
* `POST /api/chat`: Streams conversation completions using Server-Sent Events (SSE).
* `POST /api/tts`: Converts text input to WAV audio streams via local Kokoro TTS.

## Security & Offline Notice

The backend explicitly sets `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` to enforce complete network isolation during execution. 

All vector searches, LLM inference, and voice synthesis happen 100% locally on device.

