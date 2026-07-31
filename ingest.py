# ingest.py
import os
import json
import time
from tqdm import tqdm
from langchain_community.document_loaders import PyPDFLoader, TextLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_chroma import Chroma
from langchain_community.embeddings import HuggingFaceEmbeddings

DATA_DIR = "./data"
MEMORIES_DIR = "./memories"
DB_DIR = "./chroma_db"
MANIFEST_FILE = "./ingested_manifest.json"

# --- DYNAMIC TEXT SPLITTERS ---

MD_SPLITTER = RecursiveCharacterTextSplitter(
    chunk_size=500,
    chunk_overlap=80,
    separators=["\n## ", "\n### ", "\n\n", "\n", " ", ""]
)

PDF_SPLITTER = RecursiveCharacterTextSplitter(
    chunk_size=1500,
    chunk_overlap=250,
    separators=["\n\n", "\n", ". ", " ", ""]
)

# Code Splitter designed to keep functions and classes intact
CODE_SPLITTER = RecursiveCharacterTextSplitter(
    chunk_size=1000,
    chunk_overlap=150,
    separators=["\nclass ", "\ndef ", "\nfunc ", "\n\n", "\n", " ", ""]
)

def load_manifest():
    if os.path.exists(MANIFEST_FILE):
        try:
            with open(MANIFEST_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_manifest(manifest):
    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

def get_all_supported_files():
    files = []
    # Scan data, memories, and the root directory for Harvey's codebase
    for root_dir in [DATA_DIR, MEMORIES_DIR, "."]:
        if not os.path.exists(root_dir):
            continue
        for root, _, filenames in os.walk(root_dir):
            
            # Prevent scanning virtual environments, git metadata, caches, or the DB itself
            if any(ignored in root for ignored in [".venv", "chroma_db", ".git", "__pycache__"]):
                continue
                
            for fn in filenames:
                # Explicitly ignore the manifest file so Harvey doesn't ingest it
                if fn == "ingested_manifest.json":
                    continue
                    
                full_path = os.path.join(root, fn)
                ext = os.path.splitext(fn)[1].lower()
                # Includes architecture code and extension files
                if ext in [".pdf", ".txt", ".md", ".mdx", ".py", ".swift", ".js", ".ts", ".jsx", ".tsx", ".json"]:
                    files.append(full_path)
    return files

def get_domain_from_path(file_path):
    path_lower = file_path.lower()
    
    # Tag Harvey's own codebase & extension as architecture
    if any(file_path.endswith(ext) for ext in [".py", ".swift", ".js", ".ts", ".jsx", ".tsx"]) or "harvey-extension" in path_lower:
        return "architecture"
        
    if any(k in path_lower for k in ["mdn", "javascript", "typescript", "python", "github", "vscode", "wcag", "semver"]):
        return "web_dev"
    if any(k in path_lower for k in ["nng", "pucrs", "figma", "miro", "graphic_design", "books_ux", "heuristics"]):
        return "design"
    return "general"

def build_brain():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(MEMORIES_DIR, exist_ok=True)

    manifest = load_manifest()
    all_files = get_all_supported_files()

    files_to_process = []
    for fp in all_files:
        current_mtime = os.path.getmtime(fp)
        if manifest.get(fp) != current_mtime:
            files_to_process.append((fp, current_mtime))

    if not files_to_process:
        print("✨ Everything is already up to date! No new or modified documents to ingest.")
        return

    print(f"📚 Found {len(files_to_process)} new/updated file(s) out of {len(all_files)} total.")
    print("🔪 Extracting text and slicing into optimized chunks...")

    all_chunks = []
    for fp, mtime in files_to_process:
        try:
            domain = get_domain_from_path(fp)
            ext = os.path.splitext(fp)[1].lower()

            if ext == ".pdf":
                loader = PyPDFLoader(fp)
                docs = loader.load()
                chunks = PDF_SPLITTER.split_documents(docs)
            elif ext in [".py", ".swift", ".js", ".ts", ".jsx", ".tsx"]:
                loader = TextLoader(fp, encoding="utf-8")
                docs = loader.load()
                chunks = CODE_SPLITTER.split_documents(docs)
            else:
                loader = TextLoader(fp, encoding="utf-8")
                docs = loader.load()
                chunks = MD_SPLITTER.split_documents(docs)

            file_name = os.path.basename(fp)
            for chunk in chunks:
                chunk.metadata["domain"] = domain
                # Prepend source header into content to anchor vector embeddings
                if domain == "architecture":
                    chunk.page_content = f"[HARVEY LIVE SOURCE CODE - File: {file_name}]\n{chunk.page_content}"
                else:
                    chunk.page_content = f"[File: {file_name}]\n{chunk.page_content}"

            all_chunks.extend(chunks)
            print(f" 📄 [{domain.upper()}] {os.path.basename(fp)} -> {len(chunks)} chunks")
        except Exception as e:
            print(f"⚠️  Could not read {fp}: {e}")

    if not all_chunks:
        print("⚠️  No readable text found in the updated files.")
        return

    print(f"\n🧠 Processing {len(all_chunks)} total chunks with native HuggingFace embeddings...")
    
    embeddings = HuggingFaceEmbeddings(
        model_name="nomic-ai/nomic-embed-text-v1.5", 
        model_kwargs={"trust_remote_code": True}
    )

    db = Chroma(embedding_function=embeddings, persist_directory=DB_DIR)

    batch_size = 32

    print("❄️  Thermal-safe Ingestion Active (Pacing batches to keep Mac cool)...")
    for i in tqdm(range(0, len(all_chunks), batch_size), desc="Ingesting Batches", unit="batch"):
        batch = all_chunks[i : i + batch_size]
        db.add_documents(batch)
        time.sleep(0.05) 

    for fp, mtime in files_to_process:
        manifest[fp] = mtime
    save_manifest(manifest)

    print("\n✅ Ingestion complete! Harvey's brain updated efficiently and safely.")

if __name__ == "__main__":
    build_brain()