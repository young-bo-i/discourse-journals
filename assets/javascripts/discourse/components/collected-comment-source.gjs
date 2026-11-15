import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

export default class CollectedCommentSource extends Component {
  static shouldRender(args) {
    return Boolean(args.post?.dj_comment_source);
  }

  get source() {
    return this.args.outletArgs.post.dj_comment_source;
  }

  <template>
    <p class="dj-comment-source">
      <span class="dj-comment-source__text">{{this.source.text}}</span>
      {{#if this.source.url}}
        <span aria-hidden="true" class="dj-comment-source__separator">·</span>
        <a
          class="dj-comment-source__link"
          href={{this.source.url}}
          rel="nofollow noopener noreferrer"
          target="_blank"
        >{{i18n "discourse_journals.comment_source.view_original"}}</a>
      {{/if}}
    </p>
  </template>
}
