import Component from "@glimmer/component";
import bodyClass from "discourse/helpers/body-class";

// Journal topics render their own archive layout, so the page frame needs
// different topic chrome (see body.dj-journal-page in the plugin stylesheet).
export default class JournalPageShell extends Component {
  static shouldRender(outletArgs, helper) {
    const siteSettings = helper.siteSettings;
    if (!siteSettings.discourse_journals_enabled) {
      return false;
    }

    const categoryId = siteSettings.discourse_journals_category_id;
    const topic = outletArgs?.model;
    if (!categoryId || !topic?.category_id) {
      return false;
    }

    return String(topic.category_id) === String(categoryId);
  }

  <template>{{bodyClass "dj-journal-page"}}</template>
}
