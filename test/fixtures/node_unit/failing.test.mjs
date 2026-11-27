// Fixture for Malachi.Test.NodeUnit: one test that passes and one that fails.
import test from "node:test";
import assert from "node:assert/strict";

test("passes", () => assert.equal(1, 1));
test("fails", () => assert.equal(1, 2));
