import os
import json
import re
import psutil
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import List, Optional

from harvey import (
    smart_memory_router,
    get_mac_thermal_state,
    get_harvey_process_memory,
    MODEL,
    TEMPERATURE,
    DB_DIR
)

try:
    from ingest import build_brain
except ImportError:
    build_brain = None

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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
When creating or editing a file, write out the complete code block using markdown fenced code blocks (```language ... ```). Include the filename on the first line inside the block as a comment. You MAY also use <file name="filename.ext">...</file> tags surrounding the block so it gets auto-saved to Lio's Desktop.

THOUGHT PROCESS REQUIREMENT:
Before answering, you MUST provide a brief summary of your internal reasoning.
Enclose this reasoning strictly inside <thought> and </thought> tags at the very beginning of your response.
After the closing </thought> tag, write your final conversational response to Lio.

Retrieved Knowledge/Context:
{context}

Recent Conversation History:
{chat_history}

Current Question:
{question}
"""

class AttachedFile(BaseModel):
    name: str
    content: str

class ChatRequest(BaseModel):
    question: str
    chat_history: str = ""
    files: Optional[List[AttachedFile]] = []

def extract_and_save_files(text: str):
    pattern = r'<file name="(.*?)">(.*?)</file>'
    matches = re.finditer(pattern, text, re.DOTALL)
    saved_files = []
    
    for match in matches:
        filename = match.group(1).strip()
        content = match.group(2).strip()
        save_dir = os.path.expanduser("~/Desktop/Harvey_Generated_Files")
        os.makedirs(save_dir, exist_ok=True)
        path = os.path.join(save_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        saved_files.append(filename)
    return saved_files

@app.get("/api/metrics")
async def get_metrics():
    sys_ram = psutil.virtual_memory()
    sys_cpu = psutil.cpu_percent(interval=None)
    thermal = get_mac_thermal_state()
    harvey_ram_gb, harvey_cpu = get_harvey_process_memory()
    
    return {
        "sys_ram_pct": f"{sys_ram.percent}%",
        "sys_ram_gb": f"{(sys_ram.used / (1024**3)):.1f} GB",
        "sys_cpu": f"{sys_cpu}%",
        "thermal": thermal,
        "harvey_ram_gb": f"{harvey_ram_gb:.2f} GB",
        "harvey_cpu": f"{harvey_cpu:.1f}%"
    }

@app.post("/api/chat")
async def chat_endpoint(req: ChatRequest):
    full_prompt = req.question
    
    # Handle Multi-File Context Insertion
    if req.files and len(req.files) > 0:
        file_context = ""
        for file in req.files:
            file_context += f"\n\n--- [ Attached File: {file.name} ] ---\n```\n{file.content}\n```\n"
        full_prompt = file_context + "\nUser Question: " + req.question

    auto_fact, target_file = smart_memory_router(req.question, req.chat_history)
    memory_toast = None
    
    if auto_fact:
        if build_brain:
            try:
                build_brain()
            except Exception:
                pass
        memory_toast = f"Harvey updated his memory regarding {auto_fact}"

    from langchain_ollama import ChatOllama, OllamaEmbeddings
    from langchain_chroma import Chroma
    from langchain_core.prompts import ChatPromptTemplate
    from langchain_core.runnables import RunnableLambda
    from langchain_core.output_parsers import StrOutputParser
    from datetime import datetime
    
    embeddings = OllamaEmbeddings(model="nomic-embed-text")
    db = Chroma(persist_directory=DB_DIR, embedding_function=embeddings)
    retriever = db.as_retriever(search_kwargs={"k": 6})
    
    # LOW-RAM & COOL CPU SETTINGS: num_thread=1, keep_alive=0m
    llm = ChatOllama(
        model=MODEL, 
        temperature=TEMPERATURE, 
        num_ctx=2048, 
        keep_alive="0m", 
        num_thread=1
    )
    prompt = ChatPromptTemplate.from_template(SYSTEM_PROMPT)
    
    def format_docs(docs):
        return "\n\n".join(doc.page_content for doc in docs)
        
    def optimize_search_query(x):
        q = x["question"].lower()
        if any(word in q for word in [" i ", " my ", " me ", " i'm ", " i am ", "degree", "education", "study"]):
            return f"Lio profile education memories {x['question']}"
        return x["question"]

    chain = (
        {
            "context": RunnableLambda(optimize_search_query) | retriever | format_docs, 
            "chat_history": RunnableLambda(lambda x: x["chat_history"]),
            "question": RunnableLambda(lambda x: x["question"]),
            "current_time": RunnableLambda(lambda x: datetime.now().strftime("%A, %B %d, %Y at %I:%M %p"))
        }
        | prompt
        | llm
        | StrOutputParser()
    )
    
    def event_stream():
        if memory_toast:
            yield f"data: {json.dumps({'toast': memory_toast})}\n\n"
            
        full_response = ""
        try:
            for chunk in chain.stream({"question": full_prompt, "chat_history": req.chat_history}):
                full_response += chunk
                yield f"data: {json.dumps({'chunk': chunk})}\n\n"
            
            saved_files = extract_and_save_files(full_response)
            for file in saved_files:
                yield f"data: {json.dumps({'toast': f'Auto-saved copy to Desktop: {file}'})}\n\n"
                
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)