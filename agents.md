# agents.md

## Project Overview

This repository provides a **thin, opinionated wrapper around `llama_cpp.server`**.

It is **not** a full RAG stack, vector DB, or tool framework.  
Its only purpose is to:

- Run **exactly one GGUF LLM model** at a time
- Expose it via an **OpenAI-compatible HTTP API**
- Provide a **simple CLI** to start/stop/restart the server and choose a model
- Require an **API key** so not everyone on the network can call it

All embedding, retrieval, RAG, and “business logic” live **outside** this project.
This server is only the **orchestration / reasoning LLM**, nothing more.

---

## Directory Structure

From the perspective of this file (`agents.md`), the project root looks like:

```text
./
  console.sh        # main CLI entrypoint for humans / scripts
  agents.md         # this documentation file
  runtime/
    install.sh      # one-time installer (venv + deps + config + fallback model)
    config.env      # generated configuration (paths, host/port, API key, etc.)
    .venv/          # Python virtualenv with llama-cpp-python[server], huggingface_hub
    logs/
      llama_server.log
  models/
    *.gguf          # one or more GGUF LLM model files (downloaded or copied here)
