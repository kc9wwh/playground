import asyncio
import re
import subprocess
import sys

# Auto-install dependencies if missing
try:
    import edge_tts
    from pypdf import PdfReader
except ImportError:
    print("Installing required dependencies...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "edge-tts", "pypdf"])
    print("Dependencies installed. Please run the script again.\n")
    sys.exit(0)

# Auto-update edge-tts to latest version
subprocess.check_call(
    [sys.executable, "-m", "pip", "install", "--upgrade", "edge-tts", "-q"]
)

# Microsoft Azure Neural Voice (Free via edge-tts)
# Preview voices here: https://tts.travisvn.com/
VOICE = "en-US-AvaMultilingualNeural"


def extract_and_clean_text(pdf_path):
    reader = PdfReader(pdf_path)
    total_pages = len(reader.pages)
    full_text = ""

    print(f"\nExtracting text from {total_pages} pages...")

    # Regex to find standalone page numbers (e.g., " 12 ", "Page 12")
    # Adjust this pattern based on the specific PDF formatting
    page_number_pattern = re.compile(r"^\s*(page\s*)?\d+\s*$", re.IGNORECASE)

    # Regex for known headers (optional)
    header_pattern = re.compile(r"^[A-Z\s]{5,}$")  # Example: ALL CAPS HEADERS

    for idx, page in enumerate(reader.pages, 1):
        text = page.extract_text()
        if text:
            lines = text.split("\n")
            cleaned_lines = []
            for line in lines:
                # Skip if line matches page number regex
                if page_number_pattern.match(line):
                    continue
                # Skip specific headers if needed
                # if header_pattern.match(line): continue

                cleaned_lines.append(line)

            # Join lines and fix hyphenation from line breaks
            page_text = " ".join(cleaned_lines)
            full_text += page_text + " "

        # Progress indicator
        percentage = (idx / total_pages) * 100
        print(
            f"\rProgress: {idx}/{total_pages} pages ({percentage:.1f}%)",
            end="",
            flush=True,
        )

    print()  # New line after progress
    return full_text


async def text_to_speech(text, output_file):
    print(f"\nConverting to speech (this may take a while)...")
    char_count = len(text)
    print(f"Text length: {char_count:,} characters\n")

    # Estimate total audio size based on average TTS compression
    # Typical MP3 TTS: ~1 MB per 2800-3000 characters (varies by voice/bitrate)
    estimated_mb = char_count / 2870
    print(f"Estimated audio size: ~{estimated_mb:.1f} MB\n")

    communicate = edge_tts.Communicate(text, VOICE)

    # Track progress during conversion
    total_bytes = 0
    with open(output_file, "wb") as f:
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                f.write(chunk["data"])
                total_bytes += len(chunk["data"])
                # Show progress in MB and percentage
                mb = total_bytes / (1024 * 1024)
                percentage = min(
                    (mb / estimated_mb) * 100, 99.9
                )  # Cap at 99.9% until done
                print(
                    f"\rAudio generated: {mb:.2f} MB / ~{estimated_mb:.1f} MB ({percentage:.1f}%)",
                    end="",
                    flush=True,
                )

    # Final update with actual size
    final_mb = total_bytes / (1024 * 1024)
    print(f"\rAudio generated: {final_mb:.2f} MB (100.0%)          ")
    print(f"\nAudio saved to {output_file}")


# Main Execution
if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 pdf2mp3.py <input.pdf> <output.mp3>")
        sys.exit(1)

    pdf_path = sys.argv[1]
    output_audio = sys.argv[2]

    clean_text = extract_and_clean_text(pdf_path)
    # Optional: Slice text for testing so you don't render the whole book at once
    # clean_text = clean_text[:5000]
    asyncio.run(text_to_speech(clean_text, output_audio))
