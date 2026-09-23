#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <rime_api.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <key_sequence>\n", argv[0]);
        return 1;
    }
    const char *keys = argv[1];

    RimeApi *rime = rime_get_api();
    if (!rime) {
        fprintf(stderr, "Failed to get Rime API\n");
        return 1;
    }

    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = "/usr/share/rime-data";
    traits.user_data_dir = "/home/jackwy/.local/share/fcitx5/rime";
    traits.distribution_name = "Rime";
    traits.distribution_code_name = "wxzhh";
    traits.distribution_version = "0.1";
    traits.app_name = "rime.test";

    rime->setup(&traits);
    rime->initialize(&traits);

    RimeSessionId session_id = rime->create_session();
    if (!session_id) {
        fprintf(stderr, "Failed to create Rime session\n");
        return 1;
    }

    if (!rime->select_schema(session_id, "9jianhu")) {
        fprintf(stderr, "Failed to select 9jianhu schema\n");
        rime->destroy_session(session_id);
        return 1;
    }

    for (size_t i = 0; i < strlen(keys); ++i) {
        char k = keys[i];
        rime->process_key(session_id, k, 0);
    }

    RIME_STRUCT(RimeCommit, commit);
    if (rime->get_commit(session_id, &commit)) {
        if (commit.text) {
            printf("COMMIT: %s\n", commit.text);
        }
        rime->free_commit(&commit);
    }

    RIME_STRUCT(RimeContext, ctx);
    if (rime->get_context(session_id, &ctx)) {
        if (ctx.commit_text_preview) {
            printf("PREVIEW: %s\n", ctx.commit_text_preview);
        }
        if (ctx.composition.preedit) {
            printf("PREEDIT: %s\n", ctx.composition.preedit);
        }
        printf("CANDIDATES (%d):\n", ctx.menu.num_candidates);
        for (int i = 0; i < ctx.menu.num_candidates; ++i) {
            printf("  [%d] %s (comment: %s)\n", 
                   i + 1, 
                   ctx.menu.candidates[i].text ? ctx.menu.candidates[i].text : "",
                   ctx.menu.candidates[i].comment ? ctx.menu.candidates[i].comment : "");
        }
        rime->free_context(&ctx);
    }

    rime->destroy_session(session_id);
    rime->finalize();
    return 0;
}
