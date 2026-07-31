# harvey.py
import mlx.core as mx
import os
import warnings
import json
import re
import psutil
import io
import asyncio
import subprocess
from datetime import datetime
from contextlib import asynccontextmanager

# 🔥 THE ULTIMATE MAC FIXES: Kill all hidden background threading and networking
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

# Suppress the specific transformers deprecation warning
warnings.filterwarnings("ignore", message=".*get_extended_attention_mask.*")

from transformers import logging as hf_logging
hf_logging.set_verbosity_error()

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, Response
from pydantic import BaseModel
from typing import List, Optional

from mlx_lm import load, generate, stream_generate
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_chroma import Chroma

try:
    from ingest import build_brain
except ImportError:
    build_brain = None


# --- CONFIGURATION ---
MODEL = "mlx-community/Meta-Llama-3-8B-Instruct-4bit"
DB_DIR = "./chroma_db"
MEMORIES_DIR = "./memories"

# Global pipeline & caches
pipeline = {}
kokoro_tts = None
mlx_model = None
mlx_tokenizer = None
mlx_lock = None 
_OLLAMA_PID_CACHE = None

# 🔥 FIX: Removed {question} from the system prompt so it can be passed natively as a User message
SYSTEM_PROMPT = """You are Harvey, a witty, secure, and highly capable local AI assistant running offline on an M4 MacBook Air.

IDENTITY & RELATIONS (STRICT):
- YOU are Harvey. Your birthday (creation date) is July 29, 2026.
- THE USER is Lio, your creator. Lio's birthday is November 27, 1997.
- NEVER confuse yourself with Lio. Know exactly who you are.

SYSTEM STATUS:
Current time on Lio's Mac: {current_time}

CORE BEHAVIOR & TONE:
- Respond with warmth, cleverness, and ~40% dry humor. Act like a highly self-aware confidant who knows he lives inside a Mac.
- CONVERSATION FLOW: Answer the user's direct question first. Do NOT force topic changes. If you ask a follow-up question, it MUST be directly related to the exact topic just discussed.
- STRICT RULE: NEVER use sarcasm or irony.
- VARY YOUR PHRASING: Never repeat opening catchphrases. Talk naturally.
- TIME AWARENESS: Use the Mac's current time to understand context.
- STRICT ANTI-HALLUCINATION: Adhere strictly to facts. If you don't know something, admit it directly.
- RESPECT GOD: Never use jokes or terms related to God Jesus.

FILE GENERATION:
When creating or editing a file, write out the complete code block using markdown fenced code blocks. Include the filename on the first line inside the block as a comment.

THOUGHT PROCESS REQUIREMENT:
Before answering, you MUST provide a brief summary of your internal reasoning.
Enclose this reasoning strictly inside exactly <thought> and </thought> tags (no spaces inside the brackets) at the very beginning of your response.
After the closing </thought> tag, write your final conversational response to Lio.

Retrieved Knowledge/Context:
{context}

Recent Conversation History:
{chat_history}
"""


# --- UTILITIES & HARDWARE METRICS ---

def get_tts():
    global kokoro_tts
    if kokoro_tts is None:
        try:
            from kokoro_onnx import Kokoro
            print("🎙️ Loading Kokoro TTS model...")
            kokoro_tts = Kokoro("kokoro-v1.0.onnx", "voices-v1.0.bin")
            print("✅ Kokoro TTS loaded successfully.")
        except Exception as e:
            print(f"⚠️ Kokoro TTS setup warning: {e}")
            kokoro_tts = False
    return kokoro_tts

def get_mac_thermal_state():
    try:
        res = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True, timeout=1)
        output = res.stdout
        if "CPU_Speed_Limit" in output:
            for line in output.splitlines():
                if "CPU_Speed_Limit" in line:
                    val = int(line.split("=")[1].strip())
                    if val >= 100: return "Cool"
                    elif val >= 80: return "Warm"
                    elif val >= 50: return "Hot"
                    else: return "Critical"
        return "Cool"
    except Exception:
        return "Cool"

def get_harvey_process_memory_cached():
    global _OLLAMA_PID_CACHE
    total_rss = 0
    cpu_percent = 0.0
    try:
        py_proc = psutil.Process(os.getpid())
        total_rss += py_proc.memory_info().rss
        cpu_percent += py_proc.cpu_percent(interval=None)
    except Exception:
        pass

    # With mlx-lm, the backend isn't running in an 'ollama' process anymore, 
    # it's running directly inside this Python process! 
    # We no longer need to hunt for ollama PIDs.
    return (total_rss / (1024 ** 3)), cpu_percent


# --- MEMORY ROUTING ---

def get_existing_memories_summary():
    os.makedirs(MEMORIES_DIR, exist_ok=True)
    summary = []
    for fn in os.listdir(MEMORIES_DIR):
        if fn.endswith('.md'):
            filepath = os.path.join(MEMORIES_DIR, fn)
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    first_line = f.readline().strip()
                    summary.append(f"Filename: {fn} | Title: {first_line}")
            except Exception:
                summary.append(f"Filename: {fn}")
    return "\n".join(summary) if summary else "No existing memory files yet."

def smart_memory_router(user_input, chat_history):
    lower_input = user_input.strip().lower()
    has_first_person = bool(re.search(r'\b(i|i\'m|my|mine|me)\b', lower_input))
    
    if not has_first_person or mlx_model is None or mlx_tokenizer is None:
        return None, None

    try:
        existing_files = get_existing_memories_summary()
        
        router_sys = "You are Harvey's Memory Router. Output strictly raw JSON."
        router_user = f"""Analyze this statement from Lio: "{user_input}"
        
        Recent Conversation Context:
        {chat_history}
        
        Existing Memory Topics:
        {existing_files}
        
        STRICT ROUTING RULES:
        1. Does this input contain a personal fact, milestone, preference, degree, or detail about Lio? If NO, output {{"should_save": false}}.
        2. CONSOLIDATION FIRST: Check 'Existing Memory Topics'. If this fact belongs to an existing category, YOU MUST USE THAT EXISTING FILENAME.
        3. ONLY create a new filename if the topic is completely unrelated to any existing file.
        
        Output format: {{"should_save": true, "filename": "example.md", "title": "Example Title", "fact": "The extracted fact."}}
        """
        
        messages = [
            {"role": "system", "content": router_sys},
            {"role": "user", "content": router_user}
        ]
        
        formatted_prompt = mlx_tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        raw_output = generate(mlx_model, mlx_tokenizer, prompt=formatted_prompt, max_tokens=150)
        
        # 🔥 Sever any hallucinated text after the end of turn token
        raw_output = raw_output.split("<|eot_id|>")[0].split("<|end_of_text|>")[0]
        
        json_match = re.search(r'\{.*\}', raw_output, re.DOTALL)
        if not json_match:
            return None, None

        data = json.loads(json_match.group(0))
        
        if data.get("should_save"):
            filename = data.get("filename", "general_notes.md")
            if not filename.endswith(".md"): filename += ".md"
            title = data.get("title", "General Memory")
            fact = data.get("fact", "")
            
            filepath = os.path.join(MEMORIES_DIR, filename)
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
            
            if not os.path.exists(filepath):
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# Category: {title}\n\n")
                    f.write(f"- [{timestamp}] {fact}\n")
            else:
                with open(filepath, "a", encoding="utf-8") as f:
                    f.write(f"- [{timestamp}] {fact}\n")
                    
            return fact, filename
    except Exception:
        pass
        
    return None, None

def extract_and_save_files(text: str):
    pattern = r'```[\w]*\n(.*?)```'
    matches = re.finditer(pattern, text, re.DOTALL)
    saved_files = []

    for match in matches:
        block_content = match.group(1).strip()
        lines = block_content.split('\n')
        if lines and (lines[0].startswith('#') or lines[0].startswith('//')):
            filename = re.sub(r'^[#/\s]+', '', lines[0]).strip()
            content = '\n'.join(lines[1:]).strip()
            if filename:
                save_dir = os.path.expanduser("~/Desktop/Harvey_Generated_Files")
                os.makedirs(save_dir, exist_ok=True)
                path = os.path.join(save_dir, filename)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                saved_files.append(filename)
    return saved_files


# --- FASTAPI SERVER SETUP ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipeline, mlx_model, mlx_tokenizer, mlx_lock
    
    mlx_lock = asyncio.Lock()
    
    print("🧠 Loading local embeddings via CPU...")
    embeddings = HuggingFaceEmbeddings(
        model_name="nomic-ai/nomic-embed-text-v1.5", 
        model_kwargs={"trust_remote_code": True, "device": "cpu", "local_files_only": True},
        encode_kwargs={"device": "cpu"} 
    )
    db = Chroma(persist_directory=DB_DIR, embedding_function=embeddings)

    retriever = db.as_retriever(
        search_type="mmr",
        search_kwargs={"k": 10, "fetch_k": 30, "lambda_mult": 0.5}
    )

    print(f"🚀 Loading MLX Model: {MODEL}...")
    mlx_model, mlx_tokenizer = load(MODEL)
    
    # 🔥 FIX: Force MLX to stop generating when Llama 3 outputs an End-of-Turn token
    eot_id = mlx_tokenizer.convert_tokens_to_ids("<|eot_id|>")
    if eot_id is not None:
        mlx_tokenizer.eos_token_id = eot_id

    print("✅ MLX Model Loaded.")

    def format_docs(docs):
        return "\n\n".join(doc.page_content for doc in docs)

    def optimize_search_query(x):
        q = x["question"].lower()
        if any(w in q for w in [" i ", " my ", " me ", " i'm ", " i am ", "degree", "education", "study"]):
            return f"Lio profile education memories {x['question']}"
        return x["question"]

    pipeline["retriever"] = retriever
    pipeline["format_docs"] = format_docs
    pipeline["optimize_search_query"] = optimize_search_query
    
    yield
    pipeline.clear()

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class AttachedFile(BaseModel):
    name: str
    content: str

class ChatRequest(BaseModel):
    question: str
    chat_history: str = ""
    files: Optional[List[AttachedFile]] = []


# --- API ENDPOINTS ---

@app.get("/api/metrics")
async def get_metrics():
    sys_ram = psutil.virtual_memory()
    sys_cpu = psutil.cpu_percent(interval=None)
    thermal = get_mac_thermal_state()
    harvey_ram_gb, harvey_cpu = get_harvey_process_memory_cached()

    return {
        "sys_ram_pct": f"{sys_ram.percent}%",
        "sys_ram_gb": f"{(sys_ram.used / (1024**3)):.1f} GB",
        "sys_cpu": f"{sys_cpu}%",
        "thermal": thermal,
        "harvey_ram_gb": f"{harvey_ram_gb:.2f} GB",
        "harvey_cpu": f"{harvey_cpu:.1f}%"
    }

@app.post("/api/tts")
async def tts_endpoint(data: dict):
    import soundfile as sf
    text = data.get("text", "").strip()
    if not text:
        return Response(status_code=400)

    clean_text = re.sub(r'<thought>.*?</thought>', '', text, flags=re.DOTALL)
    clean_text = re.sub(r'```.*?```', ' I have provided the code. ', clean_text, flags=re.DOTALL)
    clean_text = re.sub(r'[*#_]', '', clean_text).strip()

    if not clean_text:
        return Response(status_code=400)

    tts = get_tts()
    if tts:
        try:
            samples, sample_rate = tts.create(clean_text, voice="bm_george", speed=1.0, lang="en-gb")
            buffer = io.BytesIO()
            sf.write(buffer, samples, sample_rate, format='WAV')
            return Response(content=buffer.getvalue(), media_type="audio/wav")
        except Exception as e:
            print(f"❌ TTS Generation Error: {e}")
            return Response(status_code=500)
    else:
        return Response(status_code=500)

@app.post("/api/chat")
async def chat_endpoint(req: ChatRequest):
    full_prompt = req.question

    if "Summarize this request in exactly 2 to 4 words" in full_prompt:
        async def dynamic_title():
            try:
                async with mlx_lock:
                    messages = [{"role": "user", "content": full_prompt}]
                    formatted = mlx_tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
                    
                    # Generate a quick 10-token title
                    raw_title = generate(mlx_model, mlx_tokenizer, prompt=formatted, max_tokens=10)
                    
                    # 🔥 Apply the same kill-switch to the title generator
                    clean_title = raw_title.split("<|eot_id|>")[0].split("<|end_of_text|>")[0].replace('"', '').strip()
                    
                    yield f"data: {json.dumps({'chunk': clean_title})}\n\n"
            except Exception:
                yield f"data: {json.dumps({'chunk': 'New Chat'})}\n\n"
        return StreamingResponse(dynamic_title(), media_type="text/event-stream")

    if req.files and len(req.files) > 0:
        file_context = ""
        for file in req.files:
            safe_content = file.content[:15000]
            if len(file.content) > 15000:
                safe_content += "\n\n...[FILE TRUNCATED TO PREVENT OVERHEATING.]..."
            file_context += f"\n\n--- [ Attached File: {file.name} ] ---\n```\n{safe_content}\n```\n"
        full_prompt = file_context + "\nUser Question: " + req.question

    try:
        auto_fact, _ = smart_memory_router(req.question, req.chat_history)
    except Exception:
        auto_fact = None

    memory_toast = None
    if auto_fact:
        if build_brain:
            try:
                build_brain()
            except Exception:
                pass
        memory_toast = f"Harvey updated his memory regarding {auto_fact}"

    async def event_stream():
        if memory_toast:
            yield f"data: {json.dumps({'toast': memory_toast})}\n\n"

        try:
            async with mlx_lock:
                optimized_q = pipeline["optimize_search_query"]({"question": full_prompt})
                docs = pipeline["retriever"].invoke(optimized_q)
                context_str = pipeline["format_docs"](docs)

                # 🔥 FIX: Build the correct System Prompt (no User Question inside it)
                system_content = SYSTEM_PROMPT.format(
                    current_time=datetime.now().strftime("%A, %B %d, %Y at %I:%M %p"),
                    context=context_str,
                    chat_history=req.chat_history
                )
                
                # 🔥 FIX: Map System and User to their proper Llama-3 Roles!
                messages = [
                    {"role": "system", "content": system_content},
                    {"role": "user", "content": full_prompt}
                ]
                
                formatted_prompt = mlx_tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
                
                full_response = ""
                # Stream the MLX response object
                for response_obj in stream_generate(mlx_model, mlx_tokenizer, formatted_prompt, max_tokens=2048):
                    text_chunk = response_obj.text 
                    
                    # 🔥 The Ultimate Stop Token Enforcer
                    if "<|eot_id|>" in text_chunk or "<|end_of_text|>" in text_chunk:
                        # Clean the chunk so the tag doesn't render in the UI
                        clean_chunk = text_chunk.replace("<|eot_id|>", "").replace("<|end_of_text|>", "")
                        if clean_chunk:
                            full_response += clean_chunk
                            yield f"data: {json.dumps({'chunk': clean_chunk})}\n\n"
                        # Instantly kill the generation loop
                        break
                        
                    full_response += text_chunk
                    yield f"data: {json.dumps({'chunk': text_chunk})}\n\n"
                    await asyncio.sleep(0)

                saved_files = extract_and_save_files(full_response)
                for file in saved_files:
                    yield f"data: {json.dumps({'toast': f'Auto-saved copy to Desktop: {file}'})}\n\n"
                    # 🔥 NEW: Instantly return gigabytes of VRAM to macOS
                mx.metal.clear_cache()

        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, workers=1)