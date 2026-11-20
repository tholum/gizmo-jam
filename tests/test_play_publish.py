"""Exercise the Play review gate and batched submission without external calls."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import play_publish
import release_games
import store_listing


class PlayPublishingTests(unittest.TestCase):
    def test_release_and_promotion_require_review_clear(self):
        for flags in (["--skip-build"], ["--promote"]):
            with self.subTest(flags=flags), patch.object(play_publish, "access_token") as token:
                with self.assertRaisesRegex(SystemExit, "no changes are in review"):
                    play_publish.main(flags)
                token.assert_not_called()

    def test_store_listing_requires_review_clear(self):
        with patch.object(play_publish, "access_token") as token:
            with self.assertRaisesRegex(SystemExit, "no changes are in review"):
                store_listing.main(["--capture"])
            token.assert_not_called()

    def test_direct_edit_commit_requires_review_clear(self):
        edit = play_publish.Edit("fixture")
        edit.id = "fixture-id"
        with patch.object(edit, "call") as call:
            with self.assertRaisesRegex(play_publish.PlayError, "no changes are in review"):
                edit.commit()
            call.assert_not_called()

    def test_multiple_tracks_share_one_upload_and_commit(self):
        tracks = ("internal", "beta", "production")
        with (
            patch.object(play_publish, "access_token", return_value="fixture"),
            patch.object(play_publish.Edit, "call", return_value={"id": "fixture-id"}) as call,
            patch.object(play_publish.Edit, "upload_bundle", return_value=110090) as upload,
            redirect_stdout(StringIO()),
        ):
            play_publish.publish(Path("fixture.aab"), 110090, "0.3.8", tracks, review_clear=True)
        upload.assert_called_once_with(Path("fixture.aab"))
        self.assertEqual(
            [record.args[:2] for record in call.call_args_list],
            [("POST", "/edits")] +
            [("PUT", f"/edits/fixture-id/tracks/{track}") for track in tracks] +
            [("POST", "/edits/fixture-id:commit")],
        )

    def test_site_release_only_prepares_android_locally(self):
        with (
            patch.object(release_games.subprocess, "run") as build,
            patch.object(play_publish, "access_token") as token,
            redirect_stdout(StringIO()),
        ):
            release_games.prepare_android(9)
        self.assertEqual(build.call_args.args[0][-3:], ["--android", "--serial", "9"])
        token.assert_not_called()


if __name__ == "__main__":
    unittest.main()
