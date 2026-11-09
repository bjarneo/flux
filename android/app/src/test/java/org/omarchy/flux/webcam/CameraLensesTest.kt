package org.omarchy.flux.webcam

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraLensesTest {
    // A phone like the Xiaomi 17 Pro Max: 1 logical back camera with a
    // wide, an ultra wide, and a periscope tele lens, and 1 front camera.
    private val xiaomi = listOf(
        Lens("0", null, "back", 0.85f),
        Lens("1", null, "front", 0.80f),
        Lens("0", "2", "back", 0.85f),
        Lens("0", "3", "back", 0.51f),
        Lens("0", "4", "back", 4.25f),
    )

    @Test fun namesTheThreeBackLensesAndTheFront() {
        val named = nameLenses(xiaomi)
        assertEquals(listOf("back", "back 0.6x", "back 5x", "front"), named.map { it.name })
        assertEquals("3", named[1].lens.physicalId)
        assertEquals("4", named[2].lens.physicalId)
        assertEquals(null, named[0].lens.physicalId)
    }

    @Test fun aLensThatIsAlsoItsOwnCameraIsListedOnce() {
        val lenses = listOf(
            Lens("0", null, "back", 1f),
            Lens("2", null, "back", 3f),
            Lens("0", "2", "back", 3f),
        )
        val named = nameLenses(lenses)
        assertEquals(listOf("back", "back 3x"), named.map { it.name })
        assertEquals(null, named[1].lens.physicalId)
    }

    @Test fun twoTeleLensesGetTheirOwnZoom() {
        val lenses = listOf(Lens("0", null, "back", 1f), Lens("0", "5", "back", 5f), Lens("0", "3", "back", 3f))
        assertEquals(listOf("back", "back 3x", "back 5x"), nameLenses(lenses).map { it.name })
    }

    @Test fun aLensWithoutFocalLengthIsNumbered() {
        val lenses = listOf(Lens("0", null, "back", 1f), Lens("7", null, "back", 0f))
        assertEquals(listOf("back", "back 2"), nameLenses(lenses).map { it.name })
    }

    @Test fun aPhoneWithOneCameraPerSideKeepsTheOldNames() {
        val lenses = listOf(Lens("1", null, "front", 1f), Lens("0", null, "back", 1f))
        assertEquals(listOf("back", "front"), nameLenses(lenses).map { it.name })
        assertEquals(emptyList<NamedLens>(), nameLenses(emptyList()))
    }

    @Test fun zoomLabels() {
        assertEquals("0.6", zoomLabel(0.6f))
        assertEquals("3", zoomLabel(2.98f))
        assertEquals("3.2", zoomLabel(3.21f))
    }

    @Test fun thePickerGroupsTheLensesByDirection() {
        val groups = cameraGroups(listOf("front", "back", "back 0.8x", "back 5x"))
        assertEquals(
            listOf(
                CameraGroup("Rear", listOf("back" to "1x", "back 0.8x" to "0.8x", "back 5x" to "5x")),
                CameraGroup("Front", listOf("front" to "Front")),
            ),
            groups,
        )
        assertEquals(listOf(CameraGroup("Rear", listOf("back" to "Rear"))), cameraGroups(listOf("back")))
        assertEquals("Back 5x", cameraTitle("back 5x"))
    }

    @Test fun aSavedLensSurvivesUntilTheCameraReportsItsList() {
        val saved = WebcamConfig(camera = "back 5x")
        assertEquals("back 5x", saved.clamped(WebcamCaps.LOOSE).camera)
        assertEquals("back 5x", saved.clamped(WebcamCaps(cameras = listOf("back", "back 5x"))).camera)
        assertEquals("back", saved.clamped(WebcamCaps(cameras = listOf("back", "front"))).camera)
    }

    @Test fun aLogicalCameraWithoutFocalLengthTakesItFromItsLenses() {
        val lenses = listOf(
            Lens("0", null, "back", 0f),
            Lens("0", "2", "back", 0.85f),
            Lens("0", "3", "back", 0.68f),
            Lens("0", "4", "back", 4.25f),
        )
        assertEquals(listOf("back", "back 0.8x", "back 5x"), nameLenses(lenses).map { it.name })
    }

    @Test fun aFrontWithSeveralLensesGetsItsOwnZooms() {
        val lenses = listOf(Lens("1", null, "front", 1f), Lens("1", "6", "front", 0.7f))
        assertEquals(listOf("front", "front 0.7x"), nameLenses(lenses).map { it.name })
        assertEquals(
            listOf(CameraGroup("Front", listOf("front" to "1x", "front 0.7x" to "0.7x"))),
            cameraGroups(listOf("front", "front 0.7x")),
        )
    }

    @Test fun aNameOfAnotherShapeGetsAGroupOfItsOwn() {
        assertEquals(
            listOf(CameraGroup("Rear", listOf("back" to "Rear")), CameraGroup("External", listOf("external" to "External"))),
            cameraGroups(listOf("external", "back")),
        )
    }

    @Test fun aMissingCameraFallsBackToTheMainOneOfItsSide() {
        val all = nameLenses(xiaomi)
        assertEquals("front", pickNamed(all, "front 9x")?.name)
        assertEquals("back 5x", pickNamed(all, "back 5x")?.name)
        assertEquals("back", pickNamed(all, "side")?.name)
        assertEquals(null, pickNamed(emptyList(), "back"))
    }

    @Test fun theClampPicksTheSameCameraAsTheOpen() {
        val caps = WebcamCaps(cameras = listOf("back", "back 5x", "front"))
        assertEquals("front", WebcamConfig(camera = "front 2").clamped(caps).camera)
        assertEquals("back", WebcamConfig(camera = "nonsense").clamped(WebcamCaps.LOOSE).camera)
        assertEquals("back 0.8x", WebcamConfig(camera = "back 0.8x").clamped(WebcamCaps.LOOSE).camera)
    }

    @Test fun theOpenCameraStaysInAFullList() {
        val many = (1..20).map { "back $it" }
        val list = cameraList(many, "back 20")
        assertEquals(MAX_CAMERAS, list.size)
        assertEquals("back 20", list.last())
        assertEquals(many.take(MAX_CAMERAS), cameraList(many, "back 1"))
        assertEquals(listOf("back"), cameraList(emptyList(), "back"))
    }

    @Test fun cameraNames() {
        for (n in listOf("back", "front", "back 0.6x", "back 5x", "back 2")) assertEquals(n, true, isCameraName(n))
        for (n in listOf("", "Back", "side", "back 5x extra", "back x")) assertEquals(n, false, isCameraName(n))
    }
}
