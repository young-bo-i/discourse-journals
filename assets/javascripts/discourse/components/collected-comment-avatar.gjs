import Component from "@glimmer/component";
import { trustHTML } from "@ember/template";
import { translateSize } from "discourse/lib/avatar-utils";

// Collected comments are anonymous, so there is no profile or user card to
// link: the avatar is a coloured initial derived from the comment's code.
export default class CollectedCommentAvatar extends Component {
  static shouldRender(args) {
    return Boolean(args.post?.dj_comment_author);
  }

  get author() {
    return this.args.outletArgs.post.dj_comment_author;
  }

  get initial() {
    return Array.from(this.author.name.trim())[0] ?? "?";
  }

  get style() {
    const size = translateSize(this.args.outletArgs.size || "large");
    const hue = parseInt(this.author.code, 16) % 360;
    return trustHTML(
      `--dj-author-hue: ${hue}; --dj-author-size: ${size}px; width: ${size}px; height: ${size}px`
    );
  }

  <template>
    <div class="post-avatar">
      <span
        aria-hidden="true"
        class="avatar main-avatar dj-collected-avatar"
        style={{this.style}}
      >{{this.initial}}</span>
    </div>
  </template>
}
