import os
import re
import json
import psutil
import subprocess
from datetime import datetime

import streamlit as st
from langchain_ollama import ChatOllama, OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnableLambda
from langchain_core.output_parsers import StrOutputParser

try:
    from ingest import build_brain
except ImportError:
    build_brain = None

# --- CONFIGURATION ---
MODEL = "llama3.1:8b-instruct-q4_K_M"
TEMPERATURE = 0.1
DB_DIR = "./chroma_db"
MEMORIES_DIR = "./memories"

# Global PID cache for lightweight metrics checking
_OLLAMA_PID_CACHE = None

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

def get_mac_thermal_state():
    """Safely checks macOS Thermal State via pmset without crashing Python on Apple Silicon."""
    try:
        res = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True, timeout=1)
        output = res.stdout
        if "CPU_Speed_Limit" in output:
            for line in output.splitlines():
                if "CPU_Speed_Limit" in line:
                    val = int(line.split("=")[1].strip())
                    if val >= 100:
                        return "Cool"
                    elif val >= 80:
                        return "Warm"
                    elif val >= 50:
                        return "Hot"
                    else:
                        return "Critical"
        return "Cool"
    except Exception:
        return "Cool"

def get_harvey_process_memory():
    """Calculates active RAM and CPU usage with process PID caching to minimize polling CPU usage."""
    global _OLLAMA_PID_CACHE
    total_rss = 0
    cpu_percent = 0.0
    
    try:
        py_proc = psutil.Process(os.getpid())
        total_rss += py_proc.memory_info().rss
        cpu_percent += py_proc.cpu_percent(interval=None)
    except Exception:
        pass

    if _OLLAMA_PID_CACHE is not None:
        try:
            oproc = psutil.Process(_OLLAMA_PID_CACHE)
            if 'ollama' in oproc.name().lower():
                total_rss += oproc.memory_info().rss
                cpu_percent += oproc.cpu_percent(interval=None) or 0.0
            else:
                _OLLAMA_PID_CACHE = None
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            _OLLAMA_PID_CACHE = None

    if _OLLAMA_PID_CACHE is None:
        for proc in psutil.process_iter(['pid', 'name', 'memory_info']):
            try:
                pname = proc.info['name'] or ""
                if 'ollama' in pname.lower():
                    _OLLAMA_PID_CACHE = proc.info['pid']
                    total_rss += proc.info['memory_info'].rss
                    cpu_percent += proc.cpu_percent(interval=None) or 0.0
                    break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

    ram_gb = total_rss / (1024 ** 3)
    return ram_gb, cpu_percent

def display_sidebar_memories():
    """Renders existing memory topics cleanly in the sidebar."""
    os.makedirs(MEMORIES_DIR, exist_ok=True)
    files = [f for f in os.listdir(MEMORIES_DIR) if f.endswith('.md')]
    
    if not files:
        st.caption("No memory categories stored yet.")
        return

    for fn in files:
        filepath = os.path.join(MEMORIES_DIR, fn)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                first_line = f.readline().strip()
                clean_title = re.sub(r'^#\s*(Category:\s*)?', '', first_line)
                st.markdown(f"• **{clean_title}**\n  `{fn}`")
        except Exception:
            st.markdown(f"• `{fn}`")

def get_existing_memories_summary():
    """Reads existing memory files in ./memories/ for the LLM router prompt."""
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
    """
    Analyzes input using first-person detection, checks existing memory files,
    and aggressively consolidates related facts into existing topic files before creating new ones.
    """
    lower_input = user_input.strip().lower()
    has_first_person = bool(re.search(r'\b(i|i\'m|my|mine|me)\b', lower_input))
    
    if not has_first_person:
        return None, None

    try:
        existing_files = get_existing_memories_summary()
        router_llm = ChatOllama(model=MODEL, temperature=0.1, keep_alive="10m", num_thread=4, num_gpu=99)
        
        prompt = f"""
        You are Harvey's Memory Router. Your job is to organize Lio's memories cleanly into a FEW broad categories.
        
        Analyze this statement from Lio: "{user_input}"
        
        Recent Conversation Context:
        {chat_history}
        
        Existing Memory Topics:
        {existing_files}
        
        STRICT ROUTING RULES:
        1. Does this input contain a personal fact, milestone, preference, degree, or detail about Lio? If NO, output {{"should_save": false}}.
        2. CONSOLIDATION FIRST: Check 'Existing Memory Topics'. If this fact belongs to an existing category (e.g. degrees, schools, studies, majors ALL belong in `education_academics.md`), YOU MUST USE THAT EXISTING FILENAME.
        3. ONLY create a new filename if the topic is completely unrelated to any existing file.
        
        Output strictly raw JSON:
        {{
            "should_save": true,
            "filename": "education_academics.md",
            "title": "Education & Academics",
            "fact": "Lio holds an Associate's degree in Graphic Design."
        }}
        """
        
        raw_output = router_llm.invoke(prompt).content.strip()
        json_match = re.search(r'\{.*\}', raw_output, re.DOTALL)
        if not json_match:
            return None, None

        data = json.loads(json_match.group(0))
        
        if data.get("should_save"):
            filename = data.get("filename", "general_notes.md")
            if not filename.endswith(".md"):
                filename += ".md"
                
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

def auto_save_snippets(user_query, ai_response):
    """Auto-saves generated code snippets into memories."""
    os.makedirs(MEMORIES_DIR, exist_ok=True)
    code_blocks = re.findall(r'```(\w+)?\n(.*?)```', ai_response, re.DOTALL)
    
    if code_blocks:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"snippet_{timestamp}.md"
        filepath = os.path.join(MEMORIES_DIR, filename)
        
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# Auto-Saved Code Memory\n")
            f.write(f"**Question:** {user_query}\n\n")
            
            for i, (lang, code) in enumerate(code_blocks):
                lang_str = lang if lang else "text"
                f.write(f"### Snippet {i+1} ({lang_str})\n")
                f.write(f"```{lang_str}\n{code}\n```\n\n")
        return True
    return False

def format_chat_history(messages):
    recent = messages[-6:] if len(messages) > 6 else messages
    formatted = []
    for msg in recent:
        role = "Lio" if msg["role"] == "user" else "Harvey"
        formatted.append(f"{role}: {msg['content']}")
    return "\n".join(formatted) if formatted else "No previous conversation yet."

def optimize_search_query(x):
    query = x["question"]
    lowercase_query = query.lower()
    if any(word in lowercase_query for word in [" i ", " my ", " me ", " i'm ", " i am ", "degree", "education", "study"]):
        return f"Lio profile education memories {query}"
    return query

def render_styled_thought(thought_text):
    """Renders thoughts in a smaller, lighter gray italic font."""
    st.markdown(
        f'<div style="color: #9E9E9E; font-size: 0.82em; line-height: 1.4; font-style: italic;">{thought_text}</div>', 
        unsafe_allow_html=True
    )

st.set_page_config(page_title="Harvey AI", page_icon="🧠", layout="centered")

# --- SIDEBAR: METRICS & MEMORY BANK ---
with st.sidebar:
    st.header("📊 Hardware Metrics")
    
    sys_ram = psutil.virtual_memory()
    sys_cpu = psutil.cpu_percent(interval=None)
    thermal_state = get_mac_thermal_state()
    harvey_ram_gb, harvey_cpu = get_harvey_process_memory()
    
    col1, col2 = st.columns(2)
    with col1:
        st.metric("Mac Total RAM", f"{sys_ram.percent}%", f"{(sys_ram.used / (1024**3)):.1f} GB")
        st.metric("Mac CPU Load", f"{sys_cpu}%")
        st.metric("Thermal State", thermal_state)
    with col2:
        st.metric("Harvey RAM", f"{harvey_ram_gb:.2f} GB")
        st.metric("Harvey CPU", f"{harvey_cpu:.1f}%")
        
    st.caption(f"⚙️ Model Temp: `{TEMPERATURE}` | Context: `8192`")
    st.divider()
    
    st.header("🧠 Harvey's Memory Bank")
    st.write("Current Memory Topics:")
    display_sidebar_memories()

st.title("Harvey 🧠")
st.caption("Your Secure, Offline, Local AI")

@st.cache_resource
def load_chain():
    embeddings = OllamaEmbeddings(model="nomic-embed-text")
    db = Chroma(persist_directory=DB_DIR, embedding_function=embeddings)
    retriever = db.as_retriever(search_kwargs={"k": 6})
    
    # Metal GPU accelerated with limited CPU thread saturation for passive cooling
    llm = ChatOllama(
        model=MODEL, 
        temperature=TEMPERATURE, 
        num_ctx=8192, 
        keep_alive="10m",
        num_thread=4,
        num_gpu=99
    )
    prompt = ChatPromptTemplate.from_template(SYSTEM_PROMPT)
    
    def format_docs(docs):
        return "\n\n".join(doc.page_content for doc in docs)
        
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
    return chain

try:
    chain = load_chain()
except Exception as e:
    st.error(f"Failed to load Harvey's brain: {e}. Did you run ingest.py first?")
    st.stop()

if "messages" not in st.session_state:
    st.session_state.messages = []

# Display past chat history
for msg in st.session_state.messages:
    if msg["role"] == "assistant" and "thought" in msg and msg["thought"]:
        with st.chat_message("assistant"):
            with st.expander("Harvey's Reasoning", expanded=False):
                render_styled_thought(msg["thought"])
            st.markdown(msg["content"])
    else:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

# Chat input & execution
if user_input := st.chat_input("What would you like to know?"):
    st.session_state.messages.append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.markdown(user_input)

    history_text = format_chat_history(st.session_state.messages[:-1])

    # 1. Smart Memory Check
    auto_fact, target_file = smart_memory_router(user_input, history_text)
    if auto_fact:
        if build_brain:
            try:
                build_brain()
                load_chain.clear()
            except Exception:
                pass
        
        st.toast(f"[ Harvey updated his memory regarding {auto_fact} ]")

    # 2. Response streaming with strict thought isolation
    with st.chat_message("assistant"):
        with st.spinner("Harvey is thinking..."):
            thought_container = st.empty()
            response_container = st.empty()
            
            raw_stream = chain.stream({"question": user_input, "chat_history": history_text})
            
            full_text = ""
            thought_content = ""
            response_content = ""
            
            for chunk in raw_stream:
                full_text += chunk
                
                open_match = re.search(r'<(thought|summary|think)>', full_text, re.IGNORECASE)
                close_match = re.search(r'</(thought|summary|think)>', full_text, re.IGNORECASE)

                if not open_match:
                    if full_text.lstrip().startswith("<") and ">" not in full_text:
                        pass
                    else:
                        response_container.markdown(full_text + "▌")
                elif open_match and not close_match:
                    thought_content = full_text[open_match.end():].strip()
                    with thought_container.container():
                        with st.expander("Thinking...", expanded=True):
                            render_styled_thought(thought_content + "▌")
                    response_container.empty()
                else:
                    thought_content = full_text[open_match.end():close_match.start()].strip()
                    response_content = full_text[close_match.end():].lstrip()
                    
                    with thought_container.container():
                        with st.expander("Harvey's Reasoning", expanded=False):
                            render_styled_thought(thought_content)
                            
                    if response_content:
                        response_container.markdown(response_content + "▌")

        if response_content:
            response_container.markdown(response_content.strip())
        else:
            clean_fallback = re.sub(r'</?(thought|summary|think)>', '', full_text).strip()
            response_container.markdown(clean_fallback)
            response_content = clean_fallback
            
        if auto_save_snippets(user_input, response_content):
            st.toast("[ Code snippet auto-saved. ]")

    st.session_state.messages.append({
        "role": "assistant", 
        "content": response_content.strip(),
        "thought": thought_content.strip()
    })