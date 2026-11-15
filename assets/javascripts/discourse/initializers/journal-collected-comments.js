import { withPluginApi } from "discourse/lib/plugin-api";
import CollectedCommentAvatar from "../components/collected-comment-avatar";
import CollectedCommentPosterName from "../components/collected-comment-poster-name";
import CollectedCommentSource from "../components/collected-comment-source";

export default {
  name: "journal-collected-comments",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_journals_enabled) {
      return;
    }

    withPluginApi((api) => {
      // These connectors only render for collected comments; every other post
      // keeps core's avatar and name. The source note is only serialized while
      // its setting is on.
      api.renderInOutlet("post-avatar", CollectedCommentAvatar);
      api.renderInOutlet(
        "post-meta-data-poster-name",
        CollectedCommentPosterName
      );
      api.renderInOutlet(
        "post-content-cooked-html__after",
        CollectedCommentSource
      );
      api.registerValueTransformer("post-class", ({ value, context }) =>
        context.post?.dj_comment_author
          ? [...value, "dj-collected-comment"]
          : value
      );
    });
  },
};
