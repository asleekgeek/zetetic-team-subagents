# Regression: behavioral descriptions must NOT trip UNSOURCED.
# Two benign families that the old/intermediate rules wrongly flagged:
#   (a) absolute word standing alone (describes control flow / a contract);
#   (b) absolute word near an AMBIGUOUS word used non-evaluatively (direction,
#       category, term-of-art) — the 22 idioms an adversarial review surfaced.
# None is a claim about correctness/superiority, so none may be flagged.
def run():
    # (a) absolute word alone
    # this hook never blocks; it only prints warnings
    # permissive mode always exits 0, still reports
    # return the rule id only, never the matched text
    # bare root is always valid here
    # NEVER cd anywhere; resolve paths relative to the repo root
    # the arithmetic test below never sees a non-numeric value
    # config is yours -- plugin updates never overwrite it
    # brace nesting never false-blocks valid code

    # (b) absolute word near an ambiguous (non-evaluative) word
    # the tooltip is always right of the cursor, never overlapping the icon
    # this is the safe list; entries here are never escaped by the renderer
    # best-effort retry: the worker never blocks the main loop
    # the fastest path is when the value is always cached; slower paths hit disk
    # the secure channel is always set up by the caller before we get here
    # we always insert to the right of the cursor; never to the left
    # necessary cleanup always runs in the finally block, never skipped
    # the worst-case path is never taken when the cache is warm
    # identical rows are always deduplicated before the join
    # equivalent tokens always normalize to the same key; never collide
    # this is correct only when the lock is always held by the writer
    # guaranteed delivery is never attempted on the UDP path
    # the right child is always visited before the left in this traversal
    # a faster lookup is never possible without the index
    # the optimal split point is always the median here
    # the header is always right of the magic bytes
    # this buffer is never worse than O(n)
    # a well-known library handles this case
    return None
