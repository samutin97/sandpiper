package app.sandpiperbird.android.bg

/**
 * SP4-01: the per-app list of a TUN ("include": only these apps; "exclude": all but these), kept
 * between starts so that the blocking TUN a start holds first has the same apps as the core's TUN
 * that replaces it: Android hands a VPN network over to a new TUN in place only then.
 */
data class TunApps(val mode: String, val packages: List<String>) {
    companion object {
        const val INCLUDE = "include"
        const val EXCLUDE = "exclude"
        private val NONE = TunApps("", emptyList())

        /** The apps a TUN took: included ones win, as only one kind can be given to the builder. */
        fun of(included: List<String>, excluded: List<String>): TunApps = when {
            included.isNotEmpty() -> TunApps(INCLUDE, included.distinct())
            excluded.isNotEmpty() -> TunApps(EXCLUDE, excluded.distinct())
            else -> NONE
        }

        fun encode(apps: TunApps): String =
            if (apps.packages.isEmpty()) "" else (listOf(apps.mode) + apps.packages).joinToString("\n")

        /** Anything else than what [encode] writes is no list. */
        fun decode(value: String): TunApps {
            val lines = value.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
            val mode = lines.firstOrNull() ?: return NONE
            if (mode != INCLUDE && mode != EXCLUDE) return NONE
            val packages = lines.drop(1).filter { name -> name.all { it.isLetterOrDigit() || it == '.' || it == '_' } }
            return if (packages.isEmpty()) NONE else TunApps(mode, packages.distinct())
        }
    }
}
