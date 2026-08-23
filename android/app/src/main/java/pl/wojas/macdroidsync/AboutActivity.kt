package pl.wojas.macdroidsync

import android.os.Bundle
import pl.wojas.macdroidsync.databinding.ActivityAboutBinding

/** Who made this, what it costs and under what licence. */
class AboutActivity : ScreenActivity() {

    private lateinit var binding: ActivityAboutBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAboutBinding.inflate(layoutInflater)
        setContentView(binding.root)
        useToolbar(binding.toolbar, showUp = true)
        padFromInsets(binding.content)

        // Straight from the build, so it can never claim a version that was not
        // the one installed.
        binding.versionText.text = getString(R.string.about_version, BuildConfig.VERSION_NAME)
    }
}
