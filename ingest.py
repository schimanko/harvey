import os
import json
from tqdm import tqdm
from langchain_community.document_loaders import PyPDFLoader, TextLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_chroma import Chroma
from langchain_ollama import OllamaEmbeddings

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

def get_domain_from_path(file_path):
    path_lower = file_path.lower()
    
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
            else:
                loader = TextLoader(fp, encoding="utf-8")
                docs = loader.load()
                chunks = MD_SPLITTER.split_documents(docs)

            for chunk in chunks:
                chunk.metadata["domain"] = domain
                
            all_chunks.extend(chunks)
            print(f"  📄 [{domain.upper()}] {os.path.basename(fp)} -> {len(chunks)} chunks")
        except Exception as e:
            print(f"⚠️ Could not read {fp}: {e}")

    if not all_chunks:
        print("⚠️ No readable text found in the updated files.")
        return

    print(f"\n🧠 Processing {len(all_chunks)} total chunks with nomic-embed-text...")
    embeddings = OllamaEmbeddings(model="nomic-embed-text")
    
    db = Chroma(embedding_function=embeddings, persist_directory=DB_DIR)
    
    # --- TURBO INGESTION (NO THROTTLING) ---
    batch_size = 250
    
    print("🚀 Turbo Ingestion Active (No thermal throttling)...")
    for i in tqdm(range(0, len(all_chunks), batch_size), desc="Ingesting Batches", unit="batch"):
        batch = all_chunks[i : i + batch_size]
        db.add_documents(batch)
    
    for fp, mtime in files_to_process:
        manifest[fp] = mtime
    save_manifest(manifest)

    print("\n✅ Ingestion complete! Harvey's brain updated at maximum speed.")

if __name__ == "__main__":
    build_brain()