import io
import json

from pixl_worker.log import Logger, redact, redact_exception, safe_url

URL = ("https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/pixl-cloud-studio/in/"
       "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10.m4a?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKID%2F2026"
       "&X-Amz-Signature=" + "ab" * 32)


def test_safe_url_keeps_host_and_path_only():
    assert safe_url(URL) == ("0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/pixl-cloud-studio/in/"
                             "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10.m4a")


def test_redact_strips_queries_signatures_and_tokens():
    text = f"failed GET {URL} (X-Amz-Signature={'cd' * 32}) Authorization: Bearer rpa_SECRETSECRET"
    out = redact(text)
    assert "X-Amz-Algorithm" not in out and "AKID" not in out
    assert "ab" * 32 not in out and "cd" * 32 not in out
    assert "SECRETSECRET" not in out
    assert "r2.cloudflarestorage.com/pixl-cloud-studio/in/" in out


def test_redact_exception_traceback():
    try:
        raise RuntimeError(f"boom while fetching {URL}")
    except RuntimeError as exc:
        trace = redact_exception(exc)
    assert "X-Amz" not in trace and "boom while fetching" in trace


def test_logger_writes_json_lines_with_context_and_redaction():
    stream = io.StringIO()
    logger = Logger(stream=stream, level="INFO")
    logger.bind(jobKey="6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10", runpodJobId="job-1")
    logger.info("stage_done", stage="separate", ms=1200, url=URL)
    logger.debug("hidden")
    lines = stream.getvalue().strip().splitlines()
    assert len(lines) == 1
    record = json.loads(lines[0])
    assert record["event"] == "stage_done" and record["level"] == "INFO"
    assert record["jobKey"].startswith("6f1c") and record["runpodJobId"] == "job-1"
    assert record["ms"] == 1200 and "X-Amz" not in record["url"]
    assert "ts" in record and "worker" in record
