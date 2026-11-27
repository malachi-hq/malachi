// Fixture for Malachi.Test.NodeUnit: two tests that pass.
import test from "node:test";
import assert from "node:assert/strict";

test("adds", () => assert.equal(1 + 1, 2));
test("concatenates", () => assert.equal("a" + "b", "ab"));
