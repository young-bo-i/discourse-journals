import Component from "@glimmer/component";

// No user link: the anonymous author has no profile, and without a
// data-user-card attribute nothing opens the posting bot's card either.
export default class CollectedCommentPosterName extends Component {
  static shouldRender(args) {
    return Boolean(args.post?.dj_comment_author);
  }

  <template>
    <span class="first username dj-collected-author">
      {{@outletArgs.post.dj_comment_author.name}}
    </span>
  </template>
}
