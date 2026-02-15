# File Classifier

A local financial document classifier that examines documents in PDF format to determine 
- **Source**: the originating institution (e.g., "HDFC", "Axis Bank")
- **Account Type**: the account category (e.g., "Credit Card", "Savings Account")
- **Statement Type**: the kind of statement (e.g., "Monthly Statement", "Interest Certificate")


The classifier extracts text from documents, and returns a candidate with confidence score. Everything runs locally — no external API calls.
A downstream extractor pipeline (out of scope) consumes this output.

This classifier will be used as a tool by a financial agent (outside the scope of this repo). Given
a file, the agent will invoke this classification tool to determine the source, account type, and 
statement type. After user confirmation, the agent will invoke another statement specific tool to
extract all the contents.


# Table of Contents
<!-- 
Procedure for generating TOC 
- Requires Markdown TOC Extension to be installed
- Open the command palette (Cmd+Shift+P)
- Type "Generate"
- Choose "Generate TOC for markdown"

Note 
- The TOC is generated only for H2 and below. 
- Specifically, TOC is NOT generated for H1.
- The following section is auto-generated. dont muck with it
-->

<!-- vscode-markdown-toc -->
* [Dependencies](#Dependencies)
* [Usage](#Usage)
	* [First-time setup](#First-timesetup)
	* [Server management](#Servermanagement)
	* [Knowledge Base](#KnowledgeBase)
* [CLI Interface](#CLIInterface)
* [Design](#Design)
* [Debugging](#Debugging)
* [Deployment](#Deployment)

<!-- vscode-markdown-toc-config
	numbering=false
	autoSave=true
	/vscode-markdown-toc-config -->
<!-- /vscode-markdown-toc -->

## <a name='Dependencies'></a>Dependencies

TBD List all the python packages and other dependencies like ollama and models etc

## <a name='Usage'></a>Usage

Instructions to use the classifier from this repo

### <a name='First-timesetup'></a>First-time setup

```bash
./setup.sh
```

### <a name='Servermanagement'></a>Server management

```bash
./start-server.sh              # Start Ollama, pull default model if needed
./stop-server.sh               # Stop Ollama server
```

### <a name='KnowledgeBase'></a>Knowledge Base

Institutions, account types, and statement types are defined in `kb.yaml`. The classifier matches documents against entries in this file. 
Documents that don't match any KB entry return an empty candidates list.

## <a name='CLIInterface'></a>CLI Interface

```bash
Usage: classify.sh [options] <file>

Options:
  --help                Show usage
  --model <name>        Ollama model (default: llama3.1:8b)
  --kb <path>           Knowledge base file (default: ./kb.yaml)
  --timeout <seconds>   LLM request timeout (default: 60)
  --verbose             Show intermediate steps on stderr

Arguments:
  <file>                Path to input file
```

Output format on successful extraction

```json
{
  "input": {
    "file": "statement_jan2025.pdf",
    "file_type": "pdf"
  },
  "result": {
    "status" : "success",
    "confidence": "HIGH",
    "issuer": "...",
    "account_type" : "...",
    "statement_type" : "..."
  },
  "additional_info" : {
    "pages_analyzed": [1, 12],
    "text_analysis" : {
        "status" : "success",
        "confidence": "HIGH",
        "issuer": "...",
        "account_type" : "...",
        "statement_type" : "...",
        "evidence" : [
            ... list of matching fingerprints ...
        ]
    },
    "llm_classification" : {
        "status" : "success",
        "confidence": "HIGH",
        "issuer": "...",
        "account_type" : "...",
        "statement_type" : "...",
        "evidence" : [
           .. list of evidence matching ....
        ]
    }
  }
}
```
Notes
- `status` can be "success" or "no_match" or "error"
- `confidence` can be `HIGH`, `MEDIUM` or `LOW`

Output format on error 
```json
{
  "file": "bad.txt",
  "error": "... details of error ...."
}
```

**Exit Codes**

- `0` : Classified successfully 
- `1` : No match or not classifiable
- `2` : Error (unsupported file, server down, extraction failure, etc.)


## <a name='Design'></a>Design

See [DESIGN.md](DESIGN.md) for the full design document covering architecture, classification algorithm, prompt structure, output format, error handling, and future enhancements.

## <a name='Debugging'></a>Debugging
While user should use only the top-level `classifier.sh`, the lower-level scripts can also be used directly for debugging

TBD - clean this up ...

  ./classify.sh --verbose test-data/AAA.pdf > output.txt 2>&1
   ./classify.sh --verbose test-data/FFF.pdf > output.txt 2>&1

  /Users/sdaas/dev/pdf-classifier/.venv/bin/python3 /Users/sdaas/dev/pdf-classifier/scripts/extract_pdf.py test-data/FFF.pdf
  /Users/sdaas/dev/pdf-classifier/.venv/bin/python3 /Users/sdaas/dev/pdf-classifier/scripts/llm_classifier.py /var/folders/xj/kyvcg17n4fl2jrct8x9mchbw0000gp/T/tmp.DWctcKAoOI /Users/sdaas/dev/pdf-classifier/kb.yaml --model llama3.1:8b --timeout 60 --verbose

## <a name='Deployment'></a>Deployment

The classification scripts in this repo will ultimately be used as a tool in a LLM based financial agent. This
section contains the process for packaging and deploying

TBD