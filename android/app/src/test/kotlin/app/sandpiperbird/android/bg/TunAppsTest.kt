package app.sandpiperbird.android.bg

import org.junit.Assert.assertEquals
import org.junit.Test

class TunAppsTest {
    @Test
    fun theListOfATunComesBackAsItWas() {
        val exclude = TunApps.of(emptyList(), listOf("ru.example.bank", "com.example.shop", "ru.example.bank"))
        assertEquals(TunApps(TunApps.EXCLUDE, listOf("ru.example.bank", "com.example.shop")), exclude)
        assertEquals(exclude, TunApps.decode(TunApps.encode(exclude)))
        val include = TunApps.of(listOf("org.example.browser", "app.example.self"), emptyList())
        assertEquals(include, TunApps.decode(TunApps.encode(include)))
    }

    @Test
    fun noListIsAllApps() {
        val none = TunApps.of(emptyList(), emptyList())
        assertEquals("", TunApps.encode(none))
        assertEquals(none, TunApps.decode(""))
        assertEquals(none, TunApps.decode("include"))
    }

    @Test
    fun anythingElseIsNoList() {
        assertEquals(TunApps("", emptyList()), TunApps.decode("all\ncom.example.app"))
        assertEquals(TunApps(TunApps.EXCLUDE, listOf("com.example.app")), TunApps.decode("exclude\ncom.example.app\nnot a package\n../x"))
    }
}
