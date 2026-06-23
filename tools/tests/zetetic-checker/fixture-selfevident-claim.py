# True positives: each line is an unsourced claim and MUST fire UNSOURCED.
# Exercises every self-evidence phrase plus a forward assert+claim pairing,
# so a mutation that drops any single branch fails the count assertion in
# run-tests.sh (test 9 expects exactly 7 findings here).
def claims():
    # everyone knows this approach is the standard          (self-evidence)
    # everybody knows the old parser is the one to keep     (self-evidence)
    # it goes without saying we prefer the new path         (self-evidence)
    # needless to say, the legacy code should go            (self-evidence)
    # this is a well-known fact about hash tables           (self-evidence)
    # trivially true that the base case holds               (self-evidence)
    # the cache lookup always works for warm keys           (assert+claim)
    return None
