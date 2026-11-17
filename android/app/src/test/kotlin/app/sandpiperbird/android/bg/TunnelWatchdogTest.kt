package app.sandpiperbird.android.bg

import app.sandpiperbird.android.bg.TunnelWatchdog.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

class TunnelWatchdogTest {
    private fun decide(startedByUser: Boolean, running: Boolean, vpnMode: Boolean = true, permitted: Boolean = true) =
        TunnelWatchdog.decide(startedByUser, running, vpnMode, permitted)

    @Test
    fun aTunnelTheUserStoppedIsNeverBroughtBack() {
        assertEquals(Decision.DISARM, decide(startedByUser = false, running = false))
        assertEquals(Decision.DISARM, decide(startedByUser = false, running = true))
        assertEquals(Decision.DISARM, decide(startedByUser = false, running = false, permitted = false))
    }

    @Test
    fun aRunningTunnelIsLeftAlone() {
        assertEquals(Decision.NOTHING, decide(startedByUser = true, running = true))
        assertEquals(Decision.NOTHING, decide(startedByUser = true, running = true, permitted = false))
    }

    @Test
    fun aKilledTunnelIsStartedAgain() {
        assertEquals(Decision.START, decide(startedByUser = true, running = false))
        // proxy mode needs no VPN permission
        assertEquals(Decision.START, decide(startedByUser = true, running = false, vpnMode = false, permitted = false))
    }

    @Test
    fun withoutTheVpnPermissionOnlyTheUserCanHelp() {
        assertEquals(Decision.ASK_PERMISSION, decide(startedByUser = true, running = false, permitted = false))
    }
}
