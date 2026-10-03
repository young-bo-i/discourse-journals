import {
  clearRender,
  fillIn,
  render,
  settled,
  triggerKeyEvent,
  waitUntil,
} from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import JournalSearchBox from "discourse/plugins/discourse-journals/discourse/connectors/topic-above-post-stream/journal-search-box";

function input(value) {
  // Keep these changes synchronous to interrupt debounced and in-flight searches.
  const element = document.querySelector(".journal-search-input");
  element.value = value;
  element.dispatchEvent(new Event("input", { bubbles: true }));
}

function journals(title) {
  return {
    topics: [{ id: 1, title, slug: "journal", tags: ["scie"], excerpt: "" }],
  };
}

module("Integration | Connector | JournalSearchBox", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.siteSettings.discourse_journals_category_id = 19;
    this.siteSettings.min_search_term_length = 3;
    this.siteSettings.tagging_enabled = true;
  });

  test("short terms do not search or open a broad category search", async function (assert) {
    let requests = 0;
    pretender.get("/journals/search", () => {
      requests++;
      return response({ topics: [] });
    });

    await render(<template><JournalSearchBox /></template>);
    await fillIn(".journal-search-input", "com");
    await triggerKeyEvent(".journal-search-input", "keydown", "Enter");
    await fillIn(".journal-search-input", "category:19");
    await triggerKeyEvent(".journal-search-input", "keydown", "Enter");
    await fillIn(".journal-search-input", "en category:19");
    await triggerKeyEvent(".journal-search-input", "keydown", "Enter");

    assert.strictEqual(
      requests,
      0,
      "short terms and filters never reach the search API"
    );
    assert
      .dom(".journal-search-no-results")
      .includesText("4", "the minimum length is explained to the user");
    assert
      .dom(".journal-search-input")
      .hasValue("en category:19", "the invalid term remains available to edit");
  });

  test("valid terms use the journal title lookup and list its results", async function (assert) {
    const requests = [];
    pretender.get("/journals/search", (request) => {
      requests.push(request);
      return response(journals("Nature Neuroscience"));
    });

    await render(<template><JournalSearchBox /></template>);
    await fillIn(".journal-search-input", "Nature");

    assert.strictEqual(requests.length, 1, "one search request is sent");
    assert.strictEqual(requests[0].queryParams.q, "Nature");
    assert.dom(".journal-search-item").includesText("Nature Neuroscience");
    assert.dom(".journal-search-item .discourse-tag").hasText("scie");
  });

  test("shortening input cancels a pending search", async function (assert) {
    let requests = 0;
    pretender.get("/journals/search", () => {
      requests++;
      return response({ topics: [] });
    });

    await render(<template><JournalSearchBox /></template>);
    input("Nature");
    input("Nat");
    await settled();

    assert.strictEqual(requests, 0, "the stale search is not sent");
    assert.dom(".journal-search-results").doesNotExist();
  });

  test("changing input aborts an in-flight search and keeps only new results", async function (assert) {
    const requests = [];
    let resolveFirst;
    pretender.get("/journals/search", (request) => {
      requests.push(request);

      if (requests.length === 1) {
        return new Promise((resolve) => {
          resolveFirst = () => resolve(response(journals("Old result")));
        });
      }
      return response(journals("New result"));
    });

    await render(<template><JournalSearchBox /></template>);
    input("Nature");
    await waitUntil(() => requests.length === 1);
    input("Science");
    await waitUntil(() => requests.length === 2);
    resolveFirst();
    await settled();

    assert.dom(".journal-search-results").includesText("New result");
    assert.dom(".journal-search-results").doesNotIncludeText("Old result");
  });

  test("destroying the box cancels a pending search", async function (assert) {
    let requests = 0;
    pretender.get("/journals/search", () => {
      requests++;
      return response({ topics: [] });
    });

    await render(<template><JournalSearchBox /></template>);
    input("Nature");
    await clearRender();

    assert.strictEqual(requests, 0, "no search is sent after destruction");
  });
});
