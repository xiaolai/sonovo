import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { KTX2Loader } from 'three/addons/loaders/KTX2Loader.js';
import { OBJLoader } from 'three/addons/loaders/OBJLoader.js';
import { MTLLoader } from 'three/addons/loaders/MTLLoader.js';
import { STLLoader } from 'three/addons/loaders/STLLoader.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { ThreeMFLoader } from 'three/addons/loaders/3MFLoader.js';
import { USDLoader } from 'three/addons/loaders/USDLoader.js';
import { ColladaLoader } from 'three/addons/loaders/ColladaLoader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';

const config = window.__SONOVO_MODEL__;

const THEMES = {
    light: {
        grid: 0xc3c9d2,
        gridCenter: 0xa6adb7,
        point: 0x4c525a,
        environment: 0.55,
        key: 1.5,
        fill: 0.5,
        hemi: 0.6,
        backgroundTop: '#fbfbfc',
        backgroundBottom: '#eef0f2'
    },
    dark: {
        grid: 0x363c45,
        gridCenter: 0x59616d,
        point: 0xd3d7dc,
        environment: 0.55,
        key: 1.5,
        fill: 0.55,
        hemi: 0.6,
        backgroundTop: '#23272e',
        backgroundBottom: '#0e1013'
    }
};

const statusElement = document.getElementById('status');
const viewport = document.getElementById('viewport');

let renderer = null;
let scene = null;
let camera = null;
let controls = null;
let environmentTarget = null;
let environmentRenderTarget = null;
let keyLight = null;
let fillLight = null;
let hemiLight = null;
let animationMixer = null;
let clock = null;
let grid = null;
let axisGroup = null;
let modelRoot = null;
let sceneOptions = [];
let currentScene = Number.isInteger(config?.scene) && config.scene >= 0
    ? config.scene
    : 0;
let clips = [];
let pointsMaterials = [];
let dracoLoader = null;
let ktx2Loader = null;
let resizeObserver = null;
let pendingClip = null;
let pendingScene = null;
let lastFit = 0;
let lastProgressAt = 0;
let reportedError = false;
let disposed = false;
let themeName = config?.theme === 'light' ? 'light' : 'dark';
let currentClip = Number.isInteger(config?.clip) ? config.clip : 0;
let playing = config?.playing !== false;
let suspended = config?.active === false;
let wireframe = config?.wireframe === true;
let showGrid = config?.grid !== false;
let upAxis = config?.upAxis === 'y' ? 'y' : 'z';

function post(type, payload = {}) {
    const message = { v: 1, token: config?.token ?? '', type, ...payload };
    try {
        window.webkit?.messageHandlers?.sonovoModel?.postMessage(message);
    } catch (error) {
        // A missing handler is normal in a plain browser; never let logging
        // take down the renderer.
    }
}

function showStatus(title, detail) {
    if (!statusElement) return;
    statusElement.hidden = false;
    statusElement.replaceChildren();
    const strong = document.createElement('strong');
    strong.textContent = title;
    statusElement.appendChild(strong);
    if (detail) {
        const span = document.createElement('span');
        span.textContent = detail;
        statusElement.appendChild(span);
    }
}

function hideStatus() {
    if (statusElement) statusElement.hidden = true;
}

function fail(message, code = 'render') {
    const detail = String(message || 'Unknown error');
    if (!reportedError) {
        reportedError = true;
        post('error', { message: detail.slice(0, 2000), code });
    }
    showStatus('Could not display this model', detail);
}

function theme() {
    return THEMES[themeName] ?? THEMES.dark;
}

function applyTheme(mode) {
    themeName = mode === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = themeName;
    const palette = theme();
    document.documentElement.style.setProperty(
        '--stage-top',
        palette.backgroundTop
    );
    document.documentElement.style.setProperty(
        '--stage-bottom',
        palette.backgroundBottom
    );
    if (scene) scene.environmentIntensity = palette.environment;
    if (keyLight) keyLight.intensity = palette.key;
    if (fillLight) fillLight.intensity = palette.fill;
    if (hemiLight) hemiLight.intensity = palette.hemi;
    for (const material of pointsMaterials) {
        // A colored point cloud carries its own palette in the vertex
        // colors; tinting the material would multiply the theme color into
        // every point.
        if (material.color && !material.vertexColors) {
            material.color.setHex(palette.point);
        }
    }
    rebuildGrid();
}

function setupRenderer() {
    renderer = new THREE.WebGLRenderer({
        antialias: true,
        alpha: true,
        powerPreference: 'high-performance'
    });
    if (!renderer.capabilities.isWebGL2) {
        throw new Error('WebGL 2 is not available in this web view.');
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.92;
    renderer.domElement.style.touchAction = 'none';
    viewport.appendChild(renderer.domElement);

    renderer.domElement.addEventListener('webglcontextlost', (event) => {
        event.preventDefault();
        renderer.setAnimationLoop(null);
        fail('The graphics context was lost. Reload the model to continue.', 'context-lost');
    });

    scene = new THREE.Scene();
    camera = new THREE.PerspectiveCamera(42, 1, 0.001, 1000000);
    camera.position.set(3, 2, 3);
    controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.screenSpacePanning = true;
    controls.addEventListener('end', saveCamera);

    keyLight = new THREE.DirectionalLight(0xffffff, 2.0);
    keyLight.position.set(4, 6, 5);
    scene.add(keyLight);
    fillLight = new THREE.DirectionalLight(0xffffff, 0.7);
    fillLight.position.set(-5, 2, -4);
    scene.add(fillLight);
    hemiLight = new THREE.HemisphereLight(0xffffff, 0x444a52, 0.8);
    scene.add(hemiLight);

    environmentTarget = new THREE.PMREMGenerator(renderer);
    const environment = new RoomEnvironment();
    environmentRenderTarget = environmentTarget.fromScene(environment, 0.04);
    scene.environment = environmentRenderTarget.texture;
    environment.dispose?.();

    clock = new THREE.Clock();
    resizeObserver = new ResizeObserver(resizeViewport);
    resizeObserver.observe(viewport);
    window.addEventListener('resize', resizeViewport);
    window.addEventListener('pagehide', () => {
        saveCamera();
        disposeScene();
    });
    window.addEventListener('contextmenu', (event) => event.preventDefault());
    applyTheme(themeName);
    resizeViewport();
}

function resizeViewport() {
    if (!renderer || !camera) return;
    const width = Math.max(viewport.clientWidth, 1);
    const height = Math.max(viewport.clientHeight, 1);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
}

function disposeMaterial(material) {
    if (!material) return;
    for (const value of Object.values(material)) {
        if (value?.isTexture) value.dispose();
    }
    material.dispose();
}

function disposeRoots(roots) {
    const geometries = new Set();
    const materials = new Set();
    for (const root of roots) {
        if (!root) continue;
        root.traverse((object) => {
            if (object.geometry && !geometries.has(object.geometry)) {
                geometries.add(object.geometry);
                object.geometry.dispose();
            }
            const list = Array.isArray(object.material)
                ? object.material
                : object.material
                    ? [object.material]
                    : [];
            for (const material of list) {
                if (material && !materials.has(material)) {
                    materials.add(material);
                    disposeMaterial(material);
                }
            }
        });
    }
}

function resultRoots(result) {
    if (result?.scenes?.length) {
        return result.scenes.map((option) => option.object);
    }
    return result?.object ? [result.object] : [];
}

function disposeScene() {
    if (disposed) return;
    disposed = true;
    if (animationMixer && modelRoot) {
        animationMixer.stopAllAction();
        animationMixer.uncacheRoot(modelRoot);
        animationMixer = null;
    }
    if (axisGroup) {
        scene?.remove(axisGroup);
        disposeRoots(
            sceneOptions.length
                ? sceneOptions.map((option) => option.object)
                : [axisGroup]
        );
        axisGroup = null;
        modelRoot = null;
        sceneOptions = [];
    }
    resizeObserver?.disconnect();
    resizeObserver = null;
    window.removeEventListener('resize', resizeViewport);
    dracoLoader?.dispose();
    dracoLoader = null;
    ktx2Loader?.dispose();
    ktx2Loader = null;
    rebuildGrid(true);
    environmentRenderTarget?.dispose();
    environmentRenderTarget = null;
    environmentTarget?.dispose();
    environmentTarget = null;
    renderer?.setAnimationLoop(null);
    renderer?.dispose();
    renderer?.domElement?.remove();
    renderer = null;
}

function rebuildGrid(removeOnly = false) {
    if (grid) {
        scene?.remove(grid);
        grid.geometry?.dispose();
        disposeMaterial(grid.material);
        grid = null;
    }
    if (removeOnly || !showGrid || !axisGroup || !scene) return;

    const box = new THREE.Box3().setFromObject(axisGroup);
    if (box.isEmpty()) return;
    const size = box.getSize(new THREE.Vector3());
    const extent = Math.max(size.x, size.z, 1e-6) * 1.8;
    const palette = theme();
    grid = new THREE.GridHelper(
        extent,
        20,
        palette.gridCenter,
        palette.grid
    );
    const center = box.getCenter(new THREE.Vector3());
    grid.position.set(
        center.x,
        box.min.y - Math.max(extent * 0.002, 1e-6),
        center.z
    );
    grid.material.transparent = true;
    grid.material.opacity = 0.6;
    grid.material.depthWrite = false;
    scene.add(grid);
}

function applyUpAxis(next) {
    upAxis = next === 'y' ? 'y' : 'z';
    if (!axisGroup) return;
    axisGroup.rotation.x = upAxis === 'z' ? -Math.PI / 2 : 0;
    axisGroup.updateMatrixWorld(true);
    frameModel();
}

function applyWireframe(next) {
    wireframe = next === true;
    if (!axisGroup) return;
    axisGroup.traverse((object) => {
        if (!object.isMesh) return;
        const list = Array.isArray(object.material)
            ? object.material
            : [object.material];
        for (const material of list) {
            if (material && 'wireframe' in material) {
                material.wireframe = wireframe;
                material.needsUpdate = true;
            }
        }
    });
}

function cameraKey() {
    return `sonovo.model.camera:${config?.modelURL ?? ''}`;
}

function saveCamera() {
    if (!camera || !controls) return;
    try {
        sessionStorage.setItem(
            cameraKey(),
            JSON.stringify({
                position: camera.position.toArray(),
                target: controls.target.toArray()
            })
        );
    } catch (error) {
        // Session storage is a convenience; a blocked store is not fatal.
    }
}

function restoreCamera() {
    if (!camera || !controls) return false;
    try {
        const raw = sessionStorage.getItem(cameraKey());
        if (!raw) return false;
        const saved = JSON.parse(raw);
        if (!Array.isArray(saved.position) || saved.position.length !== 3) {
            return false;
        }
        if (!Array.isArray(saved.target) || saved.target.length !== 3) {
            return false;
        }
        if (![...saved.position, ...saved.target].every(Number.isFinite)) {
            return false;
        }
        camera.position.fromArray(saved.position);
        controls.target.fromArray(saved.target);
        controls.update();
        updateClipping();
        return true;
    } catch (error) {
        return false;
    }
}

function updateClipping() {
    if (!camera || !controls) return;
    const distance = Math.max(
        camera.position.distanceTo(controls.target),
        1e-6
    );
    camera.near = Math.max(distance / 1000, 1e-4);
    camera.far = Math.max(distance * 100, 10);
    camera.updateProjectionMatrix();
}

function frameModel() {
    if (!axisGroup || !camera || !controls) return;
    const box = new THREE.Box3().setFromObject(axisGroup);
    if (box.isEmpty()) return;
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const extent = Math.max(size.x, size.y, size.z);
    if (!Number.isFinite(extent) || extent <= 0) return;

    // Frame the bounding box, not its bounding sphere. A sphere around a
    // box-shaped model is up to sqrt(3) times too large, which leaves the
    // model floating in empty space. Project the box corners onto the
    // camera's right/up axes at the view direction and fit each axis.
    const fov = (camera.fov * Math.PI) / 180;
    const horizontalFov = 2 * Math.atan(Math.tan(fov / 2) * camera.aspect);
    const direction = new THREE.Vector3(1, 0.55, 1).normalize();
    const viewDirection = direction.clone().negate();
    const right = new THREE.Vector3()
        .crossVectors(viewDirection, camera.up)
        .normalize();
    const up = new THREE.Vector3()
        .crossVectors(right, viewDirection)
        .normalize();
    // Solve for the smallest distance that keeps every corner inside both
    // frustum planes. A corner closer to the camera needs more distance than
    // one behind the center, which a flat half-extent calculation misses.
    const tanVertical = Math.tan(fov / 2);
    const tanHorizontal = Math.tan(horizontalFov / 2);
    let distance = 0;
    for (const x of [box.min.x, box.max.x]) {
        for (const y of [box.min.y, box.max.y]) {
            for (const z of [box.min.z, box.max.z]) {
                const relative = new THREE.Vector3(x, y, z).sub(center);
                const depthOffset = relative.dot(viewDirection);
                distance = Math.max(
                    distance,
                    Math.abs(relative.dot(right)) / tanHorizontal - depthOffset,
                    Math.abs(relative.dot(up)) / tanVertical - depthOffset
                );
            }
        }
    }
    distance *= 1.15;
    camera.position.copy(center).addScaledVector(direction, distance);
    controls.target.copy(center);
    controls.update();
    updateClipping();
    rebuildGrid();
    saveCamera();
}

function makeGLTFLoader() {
    const loader = new GLTFLoader(manager);
    dracoLoader = new DRACOLoader(manager);
    dracoLoader.setDecoderPath('./vendor/three/examples/jsm/libs/draco/gltf/');
    loader.setDRACOLoader(dracoLoader);
    ktx2Loader = new KTX2Loader(manager);
    ktx2Loader.setTranscoderPath('./vendor/three/examples/jsm/libs/basis/');
    ktx2Loader.detectSupport(renderer);
    loader.setKTX2Loader(ktx2Loader);
    loader.setMeshoptDecoder(MeshoptDecoder);
    return loader;
}

async function loadGLTF(url) {
    // The meshopt decoder reports `supported` once its wasm is ready; wait
    // for it so a compressed file cannot race initialization.
    await MeshoptDecoder.ready.catch(() => {});
    const gltf = await makeGLTFLoader().loadAsync(url);
    const scenes = (gltf.scenes?.length ? gltf.scenes : [gltf.scene])
        .filter(Boolean);
    if (scenes.length === 0) {
        throw new Error('The glTF file contains no scenes.');
    }
    const defaultIndex = Math.max(scenes.indexOf(gltf.scene), 0);
    return {
        object: scenes[defaultIndex],
        clips: gltf.animations ?? [],
        scenes: scenes.map((scene, index) => ({
            name: scene.name || `Scene ${index + 1}`,
            object: scene
        })),
        defaultScene: defaultIndex
    };
}

async function loadOBJ(cfg) {
    const loader = new OBJLoader(manager);
    const libraries = [];
    for (const url of Array.isArray(cfg.mtlURLs) ? cfg.mtlURLs : []) {
        try {
            const mtl = new MTLLoader(manager);
            libraries.push(await mtl.loadAsync(url));
        } catch (error) {
            post('warning', {
                message: `Materials could not be loaded: ${String(error.message ?? error)}`.slice(0, 2000)
            });
        }
    }
    if (libraries.length) {
        // A file may declare several libraries, and OBJLoader asks for a
        // material by name without saying which library owns it. Preload
        // every library and resolve each name across all of them.
        const materials = new Map();
        for (const library of libraries) {
            library.preload();
            for (const [name, material] of Object.entries(library.materials)) {
                materials.set(name, material);
            }
        }
        loader.setMaterials({ create: (name) => materials.get(name) });
    }
    const object = await loader.loadAsync(cfg.modelURL);
    return { object, clips: [] };
}

function geometryMaterial(geometry, { points = false } = {}) {
    const colored = Boolean(geometry.attributes.color);
    if (points) {
        return new THREE.PointsMaterial({
            size: 0.01,
            sizeAttenuation: true,
            vertexColors: colored,
            color: colored ? 0xffffff : theme().point
        });
    }
    return new THREE.MeshStandardMaterial({
        color: colored ? 0xffffff : 0x9aa2ad,
        roughness: 0.62,
        metalness: 0.08,
        vertexColors: colored,
        flatShading: false
    });
}

async function loadSTL(url) {
    const geometry = await new STLLoader(manager).loadAsync(url);
    geometry.computeVertexNormals();
    geometry.computeBoundingBox();
    const mesh = new THREE.Mesh(geometry, geometryMaterial(geometry));
    return { object: mesh, clips: [] };
}

function readPLYHeader(buffer) {
    const bytes = new Uint8Array(
        buffer,
        0,
        Math.min(buffer.byteLength, 65536)
    );
    const text = new TextDecoder('ascii').decode(bytes);
    const end = text.indexOf('end_header');
    return end === -1 ? null : text.slice(0, end);
}

async function loadPLY(url) {
    // PLYLoader converts face UVs or face colors to nonindexed geometry, so
    // geometry.index alone cannot distinguish a mesh from a point cloud.
    const buffer = await new THREE.FileLoader(manager)
        .setResponseType('arraybuffer')
        .loadAsync(url);
    const header = readPLYHeader(buffer);
    const headerFaces = header
        ? /^\s*element\s+face\s+([1-9]\d*)\s*$/im.test(header)
        : false;
    const geometry = new PLYLoader(manager).parse(buffer);
    const hasFaces = headerFaces
        || Boolean(geometry.index && geometry.index.count >= 3);
    if (hasFaces && !geometry.attributes.normal) {
        geometry.computeVertexNormals();
    }
    const object = hasFaces
        ? new THREE.Mesh(geometry, geometryMaterial(geometry))
        : new THREE.Points(geometry, geometryMaterial(geometry, { points: true }));
    if (!hasFaces) {
        geometry.computeBoundingBox();
        const size = geometry.boundingBox.getSize(new THREE.Vector3());
        object.material.size = Math.max(size.length() / 600, 1e-5);
        pointsMaterials.push(object.material);
    }
    return { object, clips: [] };
}


async function loadFormat(cfg) {
    switch (cfg.format) {
        case 'glb':
        case 'gltf':
            return loadGLTF(cfg.modelURL);
        case 'obj':
            return loadOBJ(cfg);
        case 'stl':
            return loadSTL(cfg.modelURL);
        case 'ply':
            return loadPLY(cfg.modelURL);
        case 'fbx': {
            const object = await new FBXLoader(manager).loadAsync(cfg.modelURL);
            return { object, clips: object.animations ?? [] };
        }
        case '3mf': {
            const object = await new ThreeMFLoader(manager).loadAsync(cfg.modelURL);
            return { object, clips: object.animations ?? [] };
        }
        case 'usdz':
        case 'usda':
        case 'usdc':
        case 'usd': {
            const object = await new USDLoader(manager).loadAsync(cfg.modelURL);
            return { object, clips: object.animations ?? [] };
        }
        case 'dae': {
            const result = await new ColladaLoader(manager)
                .loadAsync(cfg.modelURL);
            return {
                object: result.scene,
                clips: result.scene.animations ?? [],
                scenes: [],
                defaultScene: 0
            };
        }
        default:
            throw new Error(`Unsupported model format: ${cfg.format}`);
    }
}

function countTriangles(geometry) {
    if (!geometry) return 0;
    const count = geometry.index
        ? geometry.index.count
        : geometry.attributes.position?.count ?? 0;
    return Math.floor(count / 3);
}

function collectStats() {
    let meshes = 0;
    let triangles = 0;
    let vertices = 0;
    const materialSet = new Set();
    const textureSet = new Set();
    const textureKeys = [
        'map', 'normalMap', 'roughnessMap', 'metalnessMap', 'emissiveMap',
        'alphaMap', 'aoMap', 'bumpMap', 'displacementMap', 'envMap',
        'lightMap', 'specularMap', 'sheenColorMap', 'clearcoatMap',
        'iridescenceMap', 'transmissionMap', 'thicknessMap'
    ];

    axisGroup?.traverse((object) => {
        if (!object.isMesh && !object.isPoints && !object.isLine) return;
        meshes += 1;
        const geometry = object.geometry;
        vertices += geometry?.attributes?.position?.count ?? 0;
        if (object.isMesh) triangles += countTriangles(geometry);
        const list = Array.isArray(object.material)
            ? object.material
            : object.material
                ? [object.material]
                : [];
        for (const material of list) {
            if (!material) continue;
            materialSet.add(material.uuid);
            for (const key of textureKeys) {
                if (material[key]?.isTexture) textureSet.add(material[key].uuid);
            }
        }
    });

    const box = axisGroup
        ? new THREE.Box3().setFromObject(axisGroup)
        : new THREE.Box3();
    const size = box.isEmpty()
        ? new THREE.Vector3()
        : box.getSize(new THREE.Vector3());
    return {
        meshes,
        triangles,
        vertices,
        materials: materialSet.size,
        textures: textureSet.size,
        animations: clips.length,
        bounds: {
            x: Number(size.x.toFixed(4)),
            y: Number(size.y.toFixed(4)),
            z: Number(size.z.toFixed(4))
        }
    };
}

function animationPayload() {
    return clips.map((clip, index) => ({
        index,
        name: String(clip.name || `Animation ${index + 1}`).slice(0, 200),
        duration: Number.isFinite(clip.duration)
            ? Number(clip.duration.toFixed(3))
            : 0
    }));
}

function activateClip(index) {
    const action = animationMixer.clipAction(clips[index]);
    action.setLoop(THREE.LoopRepeat, Infinity);
    action.reset().play();
    action.paused = !playing;
    return action;
}

function setupAnimations() {
    animationMixer = null;
    if (!modelRoot || clips.length === 0) return;
    animationMixer = new THREE.AnimationMixer(modelRoot);
    currentClip = Math.min(Math.max(currentClip, 0), clips.length - 1);
    activateClip(currentClip);
}

function selectClip(index) {
    const requested = Math.max(Number(index) || 0, 0);
    if (!clips.length) {
        // The model is still loading. Clamping against an empty list would
        // collapse every request to 0 and lose the user's selection.
        pendingClip = requested;
        return;
    }
    currentClip = Math.min(requested, clips.length - 1);
    if (!animationMixer) return;
    animationMixer.stopAllAction();
    activateClip(currentClip);
}

function setPlaying(next) {
    playing = next === true;
    if (!animationMixer) return;
    const action = animationMixer.clipAction(clips[currentClip]);
    action.paused = !playing;
}

function setScene(index) {
    const requested = Math.max(Number(index) || 0, 0);
    if (!sceneOptions.length) {
        // The model is still loading. Clamping against an empty list would
        // collapse every request to 0 and override the restored scene.
        pendingScene = requested;
        return;
    }
    const next = Math.min(requested, sceneOptions.length - 1);
    if (next === currentScene && modelRoot === sceneOptions[next].object) {
        return;
    }
    if (animationMixer && modelRoot) {
        animationMixer.stopAllAction();
        animationMixer.uncacheRoot(modelRoot);
        animationMixer = null;
    }
    if (modelRoot && axisGroup) axisGroup.remove(modelRoot);
    currentScene = next;
    modelRoot = sceneOptions[next].object;
    axisGroup.add(modelRoot);
    axisGroup.updateMatrixWorld(true);
    applyWireframe(wireframe);
    setupAnimations();
    frameModel();
    post('scene', {
        scene: currentScene,
        stats: collectStats(),
        animations: animationPayload(),
        rendererRevision: String(THREE.REVISION)
    });
}

function friendlyError(error) {
    const message = String(error?.message ?? error);
    if (/KHR_draco_mesh_compression|DRACOLoader/i.test(message)) {
        return [
            'This glTF\'s Draco-compressed geometry could not be decoded.',
            'draco'
        ];
    }
    if (/KHR_texture_basisu|KTX2/i.test(message)) {
        return [
            'This glTF\'s KTX2 textures could not be decoded.',
            'ktx2'
        ];
    }
    if (/EXT_meshopt_compression|meshopt/i.test(message)) {
        return [
            'This glTF\'s meshopt-compressed data could not be decoded.',
            'meshopt'
        ];
    }
    if (/Failed to fetch|404|Not Found|Could not load/i.test(message)) {
        return [message, 'fetch'];
    }
    return [message, 'parse'];
}

async function loadModel() {
    disposed = false;
    reportedError = false;
    showStatus('Loading model…', config?.name ?? '');
    const result = await loadFormat(config);
    if (disposed) {
        disposeRoots(resultRoots(result));
        return;
    }
    clips = result.clips ?? [];
    sceneOptions = result.scenes ?? [];
    const configuredScene = Number.isInteger(config?.scene)
        ? config.scene
        : -1;
    let desiredScene = configuredScene >= 0
        ? configuredScene
        : (Number(result.defaultScene) || 0);
    if (pendingScene !== null) {
        desiredScene = pendingScene;
        pendingScene = null;
    }
    currentScene = Math.min(
        Math.max(desiredScene, 0),
        Math.max(sceneOptions.length - 1, 0)
    );
    // Pick the scene object for the configured/default index. result.object
    // is the file's default scene, which may differ from the restored or
    // pending selection.
    modelRoot = sceneOptions[currentScene]?.object ?? result.object;
    axisGroup = new THREE.Group();
    axisGroup.add(modelRoot);
    axisGroup.rotation.x = upAxis === 'z' ? -Math.PI / 2 : 0;
    scene.add(axisGroup);
    axisGroup.updateMatrixWorld(true);

    applyWireframe(wireframe);
    setupAnimations();
    if (pendingClip !== null) {
        selectClip(pendingClip);
        pendingClip = null;
    }
    if (!restoreCamera()) {
        frameModel();
    } else {
        updateClipping();
        rebuildGrid();
    }
    hideStatus();
    post('loaded', {
        stats: collectStats(),
        animations: animationPayload(),
        scenes: sceneOptions.map((option) => option.name),
        scene: currentScene,
        rendererRevision: String(THREE.REVISION)
    });
}

function render() {
    if (suspended || !renderer || !scene || !camera) return;
    const delta = Math.min(clock?.getDelta() ?? 0, 0.1);
    if (animationMixer && playing) animationMixer.update(delta);
    controls?.update();
    renderer.render(scene, camera);
}

const manager = new THREE.LoadingManager();
manager.onProgress = (_url, loaded, total) => {
    const now = performance.now();
    if (now - lastProgressAt < 100 && loaded < total) return;
    lastProgressAt = now;
    post('progress', { loaded, total });
};

window.sonovoViewer = {
    apply(payload = {}) {
        if (payload.theme && payload.theme !== themeName) {
            applyTheme(payload.theme);
        }
        if (typeof payload.grid === 'boolean' && payload.grid !== showGrid) {
            showGrid = payload.grid;
            rebuildGrid();
        }
        if (typeof payload.wireframe === 'boolean' && payload.wireframe !== wireframe) {
            applyWireframe(payload.wireframe);
        }
        if (payload.upAxis && payload.upAxis !== upAxis) {
            applyUpAxis(payload.upAxis);
        }
        if (typeof payload.playing === 'boolean') {
            setPlaying(payload.playing);
        }
        // While a model is loading, the selection already queued is the
        // effective one. Comparing against currentClip/currentScene alone
        // would treat a later request for the default index as a no-op and
        // leave the stale queued value in place.
        const effectiveClip = pendingClip !== null ? pendingClip : currentClip;
        if (Number.isInteger(payload.clip) && payload.clip !== effectiveClip) {
            selectClip(payload.clip);
        }
        const effectiveScene = pendingScene !== null ? pendingScene : currentScene;
        if (Number.isInteger(payload.scene) && payload.scene !== effectiveScene) {
            setScene(payload.scene);
        }
        if (Number.isInteger(payload.fit) && payload.fit !== lastFit) {
            lastFit = payload.fit;
            frameModel();
        }
        if (typeof payload.active === 'boolean') {
            setActive(payload.active);
        }
    }
};

function setActive(active) {
    suspended = !active;
    if (!renderer) return;
    if (suspended) {
        renderer.setAnimationLoop(null);
    } else {
        renderer.setAnimationLoop(render);
        render();
    }
}

async function main() {
    if (!config) {
        throw new Error('The native model configuration is missing.');
    }
    if (config.theme) applyTheme(config.theme);
    setupRenderer();
    post('ready');
    if (!suspended) {
        renderer.setAnimationLoop(render);
    }
    await loadModel();
}

main().catch((error) => {
    const [message, code] = friendlyError(error);
    fail(message, code);
});

window.addEventListener('error', (event) => {
    if (!reportedError) fail(event.message, 'script');
});

window.addEventListener('unhandledrejection', (event) => {
    if (!reportedError) {
        const [message, code] = friendlyError(event.reason);
        fail(message, code);
    }
});
