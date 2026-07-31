# Security Policy

## Offline Privacy First

Harvey is designed strictly to run offline without transmitting data to external servers. 

### Key Security Safeguards
* **Network Isolation**: The backend sets `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` at runtime to prevent unintended outbound HTTP requests.
* **Local Storage**: All vector embeddings, document stores, and chat session histories remain on the local disk.

## Reporting a Vulnerability

If you discover a security vulnerability or network leak (e.g., an unintended external connection), please report it directly by opening a private security advisory on GitHub or emailing the repository maintainer. Do not disclose security vulnerabilities in public issues.