"""RAG Slice 4: retrieval eval harness + CI regression gate (spec §6).

Two layers, deliberately separate:

1. **Harness self-tests** (always run) — a tiny synthetic library with
   hand-computed recall@k / nDCG@k expectations. These prove the metric math
   and the fixture-embedder plumbing are correct. They say NOTHING about
   retrieval quality on real data.

2. **The golden-set regression gate** (skips until fixtures exist) — runs the
   owner-labeled golden queries against the frozen library snapshot through
   the REAL retrieval code paths (lexical / vector / hybrid) with embeddings
   served from a pre-recorded .npz (CI never touches the network), and fails
   any PR whose hybrid recall@10 / nDCG@10 regresses below the committed
   baseline in fixtures/eval_baseline.json.

The golden labels are OWNER-AUTHORED, never model-generated (eval-set
construction rule: labelers independent of the system under test). Until the
owner records them per fixtures/LABELING.md, the gate test SKIPS loudly and
CI stays green; committing the four fixture files arms it automatically.
"""
import json
import math
import os
import sys
import warnings

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import library_index as libindex  # noqa: E402

import eval_harness  # noqa: E402

EPS = 1e-6  # float-noise tolerance on the baseline gate (spec task)
IDCG2 = 1.0 + 1.0 / math.log2(3)  # ideal DCG@2 with two relevant docs


# ---------------------------------------------------------------------------
# Harness self-test 1: metric math against hand-computed values.
# NOT a quality eval — it validates recall@k / nDCG@k themselves.
# ---------------------------------------------------------------------------

def test_selftest_recall_at_k_hand_computed():
    # both relevant docs retrieved
    assert eval_harness.recall_at_k(["a", "b", "c", "d"], {"a", "c"}, 10) == 1.0
    # one of two relevant docs retrieved
    assert eval_harness.recall_at_k(["a", "b"], {"a", "x"}, 10) == 0.5
    # relevant doc exists but sits below the cutoff → truncation counts
    assert eval_harness.recall_at_k(["b", "c", "a"], {"a"}, 2) == 0.0
    # nothing retrieved at all
    assert eval_harness.recall_at_k([], {"a"}, 10) == 0.0


def test_selftest_ndcg_at_k_hand_computed():
    # rel docs at ranks 1 and 3 of 4: DCG = 1/log2(2) + 1/log2(4) = 1.5
    # IDCG(2 rel) = 1/log2(2) + 1/log2(3) = 1.6309297536
    assert eval_harness.ndcg_at_k(["a", "b", "c", "d"], {"a", "c"}, 10) \
        == pytest.approx(0.9197207892, abs=1e-9)
    # single relevant doc at rank 2: DCG = 1/log2(3), IDCG = 1
    assert eval_harness.ndcg_at_k(["b", "a"], {"a"}, 2) \
        == pytest.approx(0.6309297536, abs=1e-9)
    # perfect ranking
    assert eval_harness.ndcg_at_k(["a", "c", "b"], {"a", "c"}, 10) == 1.0
    # relevant doc below the cutoff → 0
    assert eval_harness.ndcg_at_k(["b", "c", "a"], {"a"}, 2) == 0.0
    assert eval_harness.ndcg_at_k([], {"a"}, 10) == 0.0


# ---------------------------------------------------------------------------
# Harness self-test 2: end-to-end plumbing on a synthetic library.
# Vectors are hand-crafted so every ranking below is fully deterministic
# (all cosine distances distinct — no tie-order dependence).
# ---------------------------------------------------------------------------

SYNTH_SNAPSHOT = [
    {"track_id": "t_acoustic", "title": "Gentle Acoustic Morning",
     "artist": "The Larks", "album": "Dawn", "genre": "folk",
     "duration": 200, "playlists": ["morning coffee"],
     "affinity": ["favorite"]},
    {"track_id": "t_metal", "title": "Thunder Metal Storm",
     "artist": "Ironworks", "album": "Forge", "genre": "metal",
     "duration": 300, "playlists": [], "affinity": []},
    {"track_id": "t_dance", "title": "Dance Floor Nights",
     "artist": "Neon Set", "album": "Pulse", "genre": "electronic",
     "duration": 240, "playlists": [], "affinity": ["recent"]},
    {"track_id": "t_ballad", "title": "Quiet Piano Ballad",
     "artist": "M. Keys", "album": "Stillness", "genre": "classical",
     "duration": 400, "playlists": [], "affinity": ["dormant"]},
]

SYNTH_QUERIES = [
    # lexical finds t_acoustic (gentle, acoustic) + t_ballad (quiet); the
    # vector agrees → hybrid top-2 is exactly the relevant pair.
    {"query_id": "sq1", "query": "quiet gentle acoustic",
     "relevant_track_ids": ["t_acoustic", "t_ballad"]},
    # relevant = {t_metal, t_dance} but the rankings place t_ballad second,
    # so recall@2 = 0.5 and nDCG@2 = 1/IDCG2 — non-trivial values.
    {"query_id": "sq2", "query": "thunder metal",
     "relevant_track_ids": ["t_metal", "t_dance"]},
]


def _unit(components: dict) -> list:
    v = [0.0] * libindex.EMBED_DIM
    for dim, w in components.items():
        v[dim] = w
    norm = math.sqrt(sum(x * x for x in v))
    return [x / norm for x in v]


def _synth_vectors() -> dict:
    vecs = {}
    for dim, row in enumerate(SYNTH_SNAPSHOT):
        doc = libindex.compose_doc(row)
        vecs[libindex.doc_hash(doc)] = _unit({dim: 1.0})
    # distinct weights on every axis → strict distance ordering, no ties
    vecs["quiet gentle acoustic"] = _unit({0: 0.8, 3: 0.5, 1: 0.1, 2: 0.05})
    vecs["thunder metal"] = _unit({1: 0.9, 3: 0.3, 0: 0.1, 2: 0.05})
    return vecs


def test_selftest_harness_end_to_end_matches_hand_computed(tmp_path):
    """Synthetic snapshot → real index → all three retrieval modes → the
    exact hand-computed metric values. Proves the plumbing, not quality."""
    result = eval_harness.run_eval(
        SYNTH_SNAPSHOT, SYNTH_QUERIES, _synth_vectors(),
        tmp_path / "selftest.db", k=2)

    # Pin the sq2 hybrid ranking end-to-end: t_metal tops both candidate
    # lists; the remaining order comes from the vector distances alone.
    per_q = {p["query_id"]: p for p in result["per_query"]}
    assert per_q["sq2"]["hybrid"]["ranked"] == ["t_metal", "t_ballad"]

    # sq1: both relevant docs fill the top-2 in every mode → 1.0 / 1.0.
    # sq2: exactly one relevant doc, at rank 1 → 0.5 / (1/IDCG2).
    expect_recall = (1.0 + 0.5) / 2
    expect_ndcg = (1.0 + 1.0 / IDCG2) / 2
    for mode in ("hybrid", "lexical", "vector"):
        m = result["modes"][mode]
        assert m["recall_at_2"] == pytest.approx(expect_recall, abs=1e-9), mode
        assert m["ndcg_at_2"] == pytest.approx(expect_ndcg, abs=1e-9), mode

    # the hybrid path really ran hybrid (sqlite-vec + fixture embedder alive)
    assert all(p["hybrid"]["mode"] == "hybrid" for p in result["per_query"])


def test_selftest_missing_fixture_vector_fails_loud(tmp_path):
    """A vector absent from the .npz must ABORT the eval, not silently
    degrade to lexical (which would gut the gate)."""
    vecs = _synth_vectors()
    doc = libindex.compose_doc(SYNTH_SNAPSHOT[0])
    del vecs[libindex.doc_hash(doc)]
    with pytest.raises(eval_harness.MissingFixtureVector):
        eval_harness.run_eval(SYNTH_SNAPSHOT, SYNTH_QUERIES, vecs,
                              tmp_path / "missing.db", k=2)
    assert not issubclass(eval_harness.MissingFixtureVector,
                          libindex.EmbedderError), \
        "MissingFixtureVector must not be swallowed by the degradation path"


def test_selftest_snapshot_loader_accepts_space_joined_strings(tmp_path):
    """The sqlite3 export in LABELING.md emits playlists/affinity as
    space-joined strings (parsed out of doc_text). Splitting on whitespace
    must compose to the identical doc_text as the original list form."""
    p = tmp_path / "snap.jsonl"
    as_string = dict(SYNTH_SNAPSHOT[0], playlists="morning coffee",
                     affinity="favorite")
    p.write_text(json.dumps(as_string) + "\n")
    rows = eval_harness.load_snapshot(p)
    assert rows[0]["playlists"] == ["morning", "coffee"]
    assert libindex.compose_doc(rows[0]) \
        == libindex.compose_doc(SYNTH_SNAPSHOT[0])


# ---------------------------------------------------------------------------
# The golden-set regression gate (spec §6). Skips until the owner records
# fixtures per fixtures/LABELING.md; arms automatically once they exist.
# ---------------------------------------------------------------------------

_missing = [p.name for p in eval_harness.GOLDEN_FILES if not p.exists()]

GOLDEN_SKIP_REASON = (
    "RETRIEVAL EVAL SKIPPED — golden fixtures not recorded yet "
    f"(missing: {', '.join(_missing)}). The owner labels ~40 queries and "
    "records embeddings per backend/tests/fixtures/LABELING.md; committing "
    "the fixture files arms this CI gate automatically."
)


@pytest.mark.skipif(bool(_missing), reason=GOLDEN_SKIP_REASON)
def test_golden_hybrid_meets_committed_baseline(tmp_path):
    """Hybrid recall@10 / nDCG@10 on the owner-labeled golden set must not
    regress below fixtures/eval_baseline.json (per-metric, EPS tolerance).
    Baseline updates are a deliberate, reviewed diff — see LABELING.md."""
    snapshot = eval_harness.load_snapshot(eval_harness.SNAPSHOT_PATH)
    queries = eval_harness.load_queries(eval_harness.QUERIES_PATH)
    eval_harness.validate_queries(queries, snapshot)
    vectors = eval_harness.load_vectors(eval_harness.VECS_PATH)
    with open(eval_harness.BASELINE_PATH) as f:
        baseline = json.load(f)

    # The baseline is only meaningful against the exact snapshot + query set
    # it was recorded from. Any drift → re-record, don't guess.
    current_hash = eval_harness.snapshot_file_hash(eval_harness.SNAPSHOT_PATH)
    if baseline.get("snapshot_hash") != current_hash \
            or baseline.get("n_queries") != len(queries):
        pytest.fail(
            "eval fixtures drifted from eval_baseline.json (snapshot hash or "
            "query count mismatch). Re-run backend/tests/"
            "record_eval_fixtures.py and commit the refreshed fixtures.")

    result = eval_harness.run_eval(snapshot, queries, vectors,
                                   tmp_path / "golden.db", k=10)
    print()
    print(eval_harness.format_report(result, baseline))

    hybrid = result["modes"]["hybrid"]
    for metric in ("recall_at_10", "ndcg_at_10"):
        got, floor = hybrid[metric], baseline["hybrid"][metric]
        assert got >= floor - EPS, (
            f"HYBRID RETRIEVAL REGRESSION: {metric} {got:.4f} fell below the "
            f"committed baseline {floor:.4f}. If the change is an intentional "
            f"trade-off, re-record the baseline (LABELING.md) so the drop is "
            f"a reviewed diff — never edit eval_baseline.json by hand.")

    # The lift claim (spec §6: hybrid's lift over BM25-only is a number, not
    # a claim) — informational: reported above, warned on if it inverts.
    lex = result["modes"]["lexical"]
    if hybrid["recall_at_10"] < lex["recall_at_10"] - EPS:
        warnings.warn(
            f"hybrid recall@10 ({hybrid['recall_at_10']:.4f}) is BELOW "
            f"lexical ({lex['recall_at_10']:.4f}) on the golden set — the "
            "hybrid lift claim does not hold on this data.")
