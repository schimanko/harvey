# Contributing to Harvey

Thank you for your interest in contributing to Harvey. This project is built as an offline-first local AI assistant for Apple Silicon.

## Guidelines

### Reporting Bugs
* Check the existing GitHub Issues before opening a new issue.
* Provide details on your macOS version, Apple Silicon chip model (e.g., M1/M2/M3/M4), and Python environment.
* Include debug log output from the macOS app's Debug Console or the FastAPI server terminal.

### Pull Requests
1. Fork the repository and create a feature branch off `main`.
2. Ensure no personal credentials, API keys, local database files (`chroma_db/`), or document stores (`data/`, `memories/`) are committed.
3. Test backend changes using `python harvey.py` and verify local offline execution.
4. Keep PR descriptions detailed and focused on a single change or feature.

### Code Style
* **Python**: Follow PEP 8 guidelines. Keep imports explicit and ensure type hints are used where applicable.
* **Swift**: Follow standard Swift API Design Guidelines for SwiftUI components.