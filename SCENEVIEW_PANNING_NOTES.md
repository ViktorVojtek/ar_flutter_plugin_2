Notes on Implementing Panning/Dragging Gestures in SceneView ARSceneView

These notes summarize how to implement panning (dragging) interactions with 3‑D objects anchored in an AR scene using the SceneView Android library (https://github.com/SceneView/sceneview-android).  They are intended for developers integrating ARSceneView in a Flutter plugin but apply equally to native Android code.

1. Understanding the Gesture APIs

Node‑level gesture callbacks

Node is the base class for any object added to a Scene.  It already implements gesture interfaces (GestureDetector.OnGestureListener, MoveGestureDetector.OnMoveListener, RotateGestureDetector.OnRotateListener, ScaleGestureDetector.OnScaleListener, etc.) and exposes a number of callback properties.  Of particular interest for dragging:
	•	onMoveBegin, onMove and onMoveEnd – These callbacks are invoked whenever the user performs a move gesture.  The OnNodeGestureListener interface defines them as part of the gesture contract ￼.  onMoveBegin signals the start of a move, onMove is called repeatedly during the drag, and onMoveEnd signals that the user lifted their finger.
	•	worldPosition property – Each Node stores its position in world coordinates.  The Node class exposes open var worldPosition: Position and describes it as the world‑space location of the node ￼.  Updating this property moves the node in the 3‑D scene.
	•	Editable flags – Node has Boolean flags: isEditable, isPositionEditable, isRotationEditable, and isScaleEditable ￼.  Setting isEditable to true makes the node respond to default editing gestures.  To allow dragging specifically, ensure that isPositionEditable is also true.
	•	Custom gesture handlers – Node exposes high‑order properties onMove, onMoveBegin and onMoveEnd (as variables) which allow you to assign custom lambdas.  For example, node.onMove = { detector, event, worldPosition -> … } lets you override the node’s default move handling.

View‑level gesture callbacks

ARSceneView exposes an onGestureListener property and a convenience method setOnGestureListener that registers callbacks for all gesture events.  The signature includes callbacks for onMoveBegin, onMove, and onMoveEnd with an additional node parameter representing the node under the finger ￼.  At the view level you can translate a node by updating its position inside these callbacks.

2. Converting touch points to world coordinates

When the user drags an object on the screen, you must convert the finger’s screen position to a position in the AR world.  SceneView provides utility functions for this:
	•	screenToWorld – An extension function on View that converts a screen coordinate (xPx, yPx) to a world‐space position.  Its documentation states that it returns a world position for a given screen position ￼.  The optional z parameter indicates depth (1.0 = near plane, 0 = infinity).  For AR objects anchored on a horizontal plane, you typically supply the plane’s height to find the intersection of the camera ray with that plane.  Alternatively, the node‑level onMove callback (with worldPosition argument) performs this conversion for you.
	•	World position via hit test – You can also obtain a world pose by performing a hit test against ARCore planes (frame.hitTest) and creating an anchor at the hit result.  This is how objects are initially placed, but for dragging a continuous plane intersection is more convenient.

3. Recommended implementation for dragging

The following steps show how to implement panning/dragging of an object that has already been placed into the AR scene.  The high‑level goal is to update the node’s worldPosition during the drag and, if necessary, re‑create its anchor after the user releases their finger.

3.1 Prepare the node
	1.	Create an anchor and anchor node – Use a plane hit test or getUpdatedPlanes() to find a horizontal plane and call createAnchor() on it.  Add an AnchorNode to the scene and set isEditable = true.  The SceneView AR sample does this when placing its first object ￼.
	2.	Add the model node – Create a ModelNode (or any other node) and attach it as a child of the anchor node.  Set the following flags:

  modelNode.isEditable = true        // allow editing gestures
modelNode.isPositionEditable = true // specifically allow translation
modelNode.isRotationEditable = true // optional – allow rotation
modelNode.isScaleEditable = true    // optional – allow scaling

3.2 Handle move gestures

There are two approaches: assigning callbacks on the node itself or registering a gesture listener on ARSceneView.

Approach A – Node‑level callbacks
Assign custom lambdas to the node’s onMoveBegin, onMove and onMoveEnd properties.  When using this approach, the SceneView gesture detector will call these lambdas automatically when the user drags the node.

val modelNode = ModelNode(/*…*/).apply {
    isEditable = true
    isPositionEditable = true

    var anchorOnMove: Anchor? = null

    // Called when the user starts dragging
    onMoveBegin = { detector, event ->
        // Optionally store the current anchor to update later
        anchorOnMove = (parent as? AnchorNode)?.anchor
        // Return true to indicate we handle the gesture
        true
    }

    // Called repeatedly while dragging.
    // worldPos is the converted world-space position of the touch point.
    onMove = { detector, event, worldPos ->
        // Keep the node at the same height as its anchor
        val currentY = worldPosition.y
        worldPosition = Position(worldPos.x, currentY, worldPos.z)
        true // inform the detector that we consumed this event
    }

    // Called when the user releases the finger
    onMoveEnd = { detector, event ->
        anchorOnMove?.let { oldAnchor ->
            // Create a new anchor at the node’s final world position
            val pose = Pose.makeTranslation(worldPosition.x, worldPosition.y, worldPosition.z)
            val newAnchor = sceneView.session?.createAnchor(pose)
            // Replace the parent AnchorNode so that ARCore keeps tracking the object
            (parent as? AnchorNode)?.anchor = newAnchor
            oldAnchor.detach() // release the old anchor
        }
    }
}

	•	Why update the anchor?  ARCore tracks anchors for world stability.  When you move a node without updating its anchor, the object will drift or snap back because the underlying anchor remains at its original position.  In onMoveEnd you create a new anchor at the final position and set it on the AnchorNode.
	•	Why clamp the Y coordinate?  The screenToWorld conversion returns a 3‑D point along a ray from the camera.  To keep the object on the plane, fix its vertical coordinate (y) to that of the original anchor.
	•	Returning true from onMoveBegin and onMove tells SceneView you handled the gesture ￼.

Approach B – View‑level gesture listener
If you need centralised gesture handling, register a listener on the ARSceneView:

sceneView.setOnGestureListener(
    onDown = { e, node -> /* not needed */ },
    onShowPress = { _, _ -> },
    onSingleTapUp = { _, _ -> },
    onScroll = { e1, e2, node, distance -> /* optional */ },
    onLongPress = { _, _ -> },
    onFling = { _, _, _, _ -> },
    onSingleTapConfirmed = { e, node -> /* used for placement */ },
    onDoubleTap = { _, _ -> },
    onDoubleTapEvent = { _, _ -> },
    onContextClick = { _, _ -> },
    onMoveBegin = { detector, event, node -> true },
    onMove = { detector, event, node ->
        if (node is Node && node.isPositionEditable) {
            // Convert the touch to world coordinates
            val worldPos = sceneView.view.screenToWorld(event.x, event.y)
            val currentY = node.worldPosition.y
            node.worldPosition = Position(worldPos.x, currentY, worldPos.z)
        }
    },
    onMoveEnd = { detector, event, node ->
        // Similar anchor update as shown above
    },
    onRotateBegin = { _, _, _ -> true },
    onRotate = { detector, event, node -> /* rotate node */ },
    onRotateEnd = { _, _, _ -> },
    onScaleBegin = { _, _, _ -> true },
    onScale = { detector, event, node -> /* scale node */ },
    onScaleEnd = { _, _, _ -> }
)

Using the view‑level listener gives you access to the node parameter so you can handle moves only for a selected object.  You still need to update the anchor on gesture end.

4. Additional tips and caveats
	•	Hit‑testing for the initial placement – Use frame.hitTest(screenX, screenY) or getUpdatedPlanes() to find a horizontal plane and create an anchor; the sample uses this pattern ￼.  Without an anchor, the object will not remain fixed in space.
	•	Depth mode and instant placement – When configuring the AR session, enable depthMode only if supported; otherwise set it to DISABLED ￼.  Panning will work regardless of depth mode.
	•	Camera gestures – SceneView includes a CameraGestureDetector that enables one‑finger orbit, two‑finger pan and pinch‑to‑zoom of the camera ￼.  If your AR experience allows the camera to move, ensure that camera gestures do not conflict with object dragging.  You can disable camera pan while dragging by temporarily setting sceneView.cameraGestureDetector.isPanEnabled = false during a move.
	•	Editable bounding box – When isEditable is true, SceneView draws a bounding box with scale/rotation handles when the node is selected.  You can hide or show these handles using the onEditingChanged callback (as in the sample code) but note that dragging can still occur even when the bounding box is hidden ￼.
	•	Smoothing transformations – Node supports smooth movement through isSmoothTransformEnabled and smoothTransformSpeed properties.  When panning objects slowly, enabling smoothing can create a more natural feel.

5. Summary

Panning/dragging an object in SceneView’s ARSceneView is achieved by responding to move gestures and updating the node’s world position, then updating its anchor.  Set isEditable and isPositionEditable to allow translation.  Use the node’s move callbacks or the view’s setOnGestureListener to handle onMoveBegin, onMove and onMoveEnd.  Convert the user’s screen coordinates to world coordinates via SceneView’s screenToWorld function or by using the world position provided by the onMove callback.  When the gesture ends, create a new ARCore anchor at the node’s new position to maintain tracking.  These steps ensure that objects can be intuitively dragged across detected planes within your AR experience.
