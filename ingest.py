import os
import json
import time
import shutil
from tqdm import tqdm
from langchain_community.document_loaders import PyPDFLoader, TextLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_chroma import Chroma
from langchain_ollama import OllamaEmbeddings

DATA_DIR = "./data"
MEMORIES_DIR = "./memories"
DB_DIR = "./chroma_db"
MANIFEST_FILE = "./ingested_manifest.json"

def load_manifest():
    """Loads recorded modification times for previously ingested files."""
    if os.path.exists(MANIFEST_FILE):
        try:
            with open(MANIFEST_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_manifest(manifest):
    """Saves updated modification timestamps."""
    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

def get_all_supported_files():
    """Finds all PDFs, TXT, MD, and MDX files across data and memories directories."""
    files = []
    for root_dir in [DATA_DIR, MEMORIES_DIR]:
        if not os.path.exists(root_dir):
            continue
        for root, _, filenames in os.walk(root_dir):
            for fn in filenames:
                full_path = os.path.join(root, fn)
                ext = os.path.splitext(fn)[1].lower()
                if ext in [".pdf", ".txt", ".md", ".mdx"]:
                    files.append(full_path)
    return files

def build_brain():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(MEMORIES_DIR, exist_ok=True)

    manifest = load_manifest()
    all_files = get_all_supported_files()
    
    # 1. Check which files are actually new or updated
    files_to_process = []
    for fp in all_files:
        current_mtime = os.path.getmtime(fp)
        if manifest.get(fp) != current_mtime:
            files_to_process.append((fp, current_mtime))

    if not files_to_process:
        print("✨ Everything is already up to date! No new or modified documents to ingest.")
        return

    print(f"📚 Found {len(files_to_process)} new/updated file(s) out of {len(all_files)} total.")
    print("🔪 Extracting text and slicing into chunks...")
    
    new_documents = []
    for fp, mtime in files_to_process:
        try:
            ext = os.path.splitext(fp)[1].lower()
            if ext == ".pdf":
                loader = PyPDFLoader(fp)
            else:
                loader = TextLoader(fp, encoding="utf-8")
            new_documents.extend(loader.load())
        except Exception as e:
            print(f"⚠️ Could not read {fp}: {e}")

    if not new_documents:
        print("⚠️ No readable text found in the updated files.")
        return

    splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
    chunks = splitter.split_documents(new_documents)

    print(f"🧠 Processing {len(chunks)} new chunks with nomic-embed-text...")
    embeddings = OllamaEmbeddings(model="nomic-embed-text")
    
    # Connect to existing database (does not wipe past data)
    db = Chroma(embedding_function=embeddings, persist_directory=DB_DIR)
    
    # --- THERMAL PROTECTION FOR M4 AIR ---
    # Small batch size + cooling pause prevents CPU/GPU heat buildup
    batch_size = 10
    pause_between_batches = 1.0  # Full-second breather for fanless M4
    
    print("🌡️ Thermal Pacing Active (keeping your fanless M4 cool)...")
    for i in tqdm(range(0, len(chunks), batch_size), desc="Ingesting Batches", unit="batch"):
        batch = chunks[i : i + batch_size]
        db.add_documents(batch)
        time.sleep(pause_between_batches)
    
    # Update manifest after successful ingestion
    for fp, mtime in files_to_process:
        manifest[fp] = mtime
    save_manifest(manifest)

    print("\n✅ Ingestion complete! Harvey's brain updated smoothly without overheating.")

if __name__ == "__main__":
    build_brain()