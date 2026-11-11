// SPDX-License-Identifier: GPL-3.0-or-later
package org.insanotic.android;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.text.format.Formatter;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Launcher activity. Makes sure the Xonotic data packs and Insanotic's own
 * pk3 are installed (showing progress on the first run), then starts the
 * engine in {@link GameActivity}.
 */
public class SetupActivity extends Activity {
	private TextView status;
	private ProgressBar bar;
	private Button retry;
	private CheckBox music;
	private final AtomicBoolean cancel = new AtomicBoolean();
	private Thread worker;
	private String fileLabel = "";

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);
		getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

		if (GameData.isReady(this)) {
			startGame();
			return;
		}
		// after an app update only Insanotic's own pk3 needs installing: no
		// questions to ask
		boolean packsPresent = GameData.packsInstalled(this);

		LinearLayout root = new LinearLayout(this);
		root.setOrientation(LinearLayout.VERTICAL);
		root.setGravity(Gravity.CENTER);
		root.setBackgroundColor(Color.rgb(16, 24, 32));
		int pad = (int) (24 * getResources().getDisplayMetrics().density);
		root.setPadding(pad, pad, pad, pad);

		TextView title = new TextView(this);
		title.setText(R.string.setup_title);
		title.setTextSize(28);
		title.setTextColor(Color.rgb(255, 106, 26));
		title.setGravity(Gravity.CENTER);
		root.addView(title);

		TextView note = new TextView(this);
		note.setText(R.string.setup_first_run);
		note.setTextColor(Color.LTGRAY);
		note.setGravity(Gravity.CENTER);
		note.setPadding(0, pad / 2, 0, pad);
		root.addView(note);

		status = new TextView(this);
		status.setTextColor(Color.WHITE);
		status.setGravity(Gravity.CENTER);
		status.setText(R.string.setup_checking);
		root.addView(status);

		bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
		bar.setMax(1000);
		bar.setIndeterminate(false);
		root.addView(bar, new LinearLayout.LayoutParams(
			(int) (420 * getResources().getDisplayMetrics().density),
			LinearLayout.LayoutParams.WRAP_CONTENT));

		music = new CheckBox(this);
		music.setText(R.string.setup_music);
		music.setTextColor(Color.LTGRAY);
		music.setVisibility(packsPresent ? View.GONE : View.VISIBLE);
		root.addView(music);

		retry = new Button(this);
		retry.setText(R.string.setup_start);
		retry.setVisibility(packsPresent ? View.GONE : View.VISIBLE);
		retry.setOnClickListener(v -> begin());
		root.addView(retry);

		setContentView(root);
		if (packsPresent)
			begin();
		else
			status.setText(R.string.setup_choose);
	}

	private void begin() {
		retry.setVisibility(View.GONE);
		music.setEnabled(false);
		bar.setIndeterminate(true);
		cancel.set(false);
		final boolean withMusic = music.isChecked();
		worker = new Thread(() -> work(withMusic), "insanotic-setup");
		worker.start();
	}

	private void work(boolean withMusic) {
		try {
			GameData.prepare(this, new GameData.Progress() {
				@Override
				public void onDownload(long done, long total) {
					runOnUiThread(() -> {
						bar.setIndeterminate(false);
						bar.setProgress(total > 0 ? (int) (done * 1000 / total) : 0);
						status.setText(getString(R.string.setup_download,
							Formatter.formatFileSize(SetupActivity.this, done),
							Formatter.formatFileSize(SetupActivity.this, total)) + "\n" + fileLabel);
					});
				}

				@Override
				public void onFile(String name, int index, int count) {
					runOnUiThread(() -> fileLabel = getString(R.string.setup_file, name, index, count));
				}

				@Override
				public void onInstall() {
					runOnUiThread(() -> {
						bar.setIndeterminate(true);
						status.setText(R.string.setup_install);
					});
				}
			}, cancel, withMusic);
			runOnUiThread(() -> {
				status.setText(R.string.setup_done);
				startGame();
			});
		} catch (GameData.Cancelled e) {
			// activity going away; nothing to show
		} catch (GameData.NoSpace e) {
			fail(getString(R.string.setup_no_space,
				Formatter.formatFileSize(this, e.needed), Formatter.formatFileSize(this, e.available)));
		} catch (Exception e) {
			fail(e.getMessage() != null ? e.getMessage() : e.toString());
		}
	}

	private void fail(String message) {
		runOnUiThread(() -> {
			bar.setIndeterminate(false);
			status.setText(getString(R.string.setup_failed, message));
			retry.setText(R.string.setup_retry);
			retry.setVisibility(View.VISIBLE);
			music.setEnabled(true);
		});
	}

	private void startGame() {
		startActivity(new Intent(this, GameActivity.class));
		finish();
	}

	@Override
	protected void onDestroy() {
		cancel.set(true);
		super.onDestroy();
	}
}
