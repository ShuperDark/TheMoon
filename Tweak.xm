#include "substrate.h"
#include <string>
#include <cstdio>
#include <chrono>
#include <memory>
#include <vector>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <cstdlib>
#include <sys/mman.h>
#include <sys/stat.h>
#include <random>
#include <cstdint>
#include <unordered_map>
#include <map>
#include <functional>
#include <cmath>
#include <chrono>
#include <libkern/OSCacheControl.h>
#include <cstddef>
#include <tuple>
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <cstdint>
#include <math.h>
#include <cstring>
#include <pthread.h>

#include <dlfcn.h>

#import <Foundation/Foundation.h>
#import "UIKit/UIKit.h"

struct TextureUVCoordinateSet;
struct CompoundTag;
struct Material;
struct BlockSource;

enum class MaterialType : int {
	DEFAULT = 0,
	DIRT,
	WOOD,
	STONE,
	METAL,
	WATER,
	LAVA,
	PLANT,
	DECORATION,
	WOOL = 11,
	BED,
	FIRE,
	SAND,
	DEVICE,
	GLASS,
	EXPLOSIVE,
	ICE,
	PACKED_ICE,
	SNOW,
	CACTUS = 22,
	CLAY,
	PORTAL = 25,
	CAKE,
	WEB,
	CIRCUIT,
	LAMP = 30,
	SLIME
};

enum class BlockSoundType : int {
	NORMAL, GRAVEL, WOOD, GRASS, METAL, STONE, CLOTH, GLASS, SAND, SNOW, LADDER, ANVIL, SLIME, SILENT, DEFAULT, UNDEFINED
};

struct Block
{
	void** vtable;
	char filler[0x90-8];
	int category;
	char filler2[0x94+0x19+0x90-4];
};

struct Item {
	void** vtable; // 0
	uint8_t maxStackSize; // 8
	int idk; // 12
	std::string atlas; // 16
	int frameCount; // 40
	bool animated; // 44
	short itemId; // 46
	std::string name; // 48
	std::string idk3; // 72
	bool isMirrored; // 96
	short maxDamage; // 98
	bool isGlint; // 100
	bool renderAsTool; // 101
	bool stackedByData; // 102
	uint8_t properties; // 103
	int maxUseDuration; // 104
	bool explodeable; // 108
	bool shouldDespawn; // 109
	bool idk4; // 110
	uint8_t useAnimation; // 111
	int creativeCategory; // 112
	float idk5; // 116
	float idk6; // 120
	char buffer[12]; // 124
	TextureUVCoordinateSet* icon; // 136
	char filler[100];
};

struct BlockItem :public Item {
	char filler[0xB0];
};

// DiggerItem (ShovelItem / PickaxeItem / HatchetItem) は 224 からブロックID毎の「適正ツール」フラグを持つ
static bool* DiggerItem$effectiveBlocks(Item* self) {
	return (bool*)((uintptr_t)self + 224);
}

struct ItemInstance {
	uint8_t count;
	uint16_t aux;
	CompoundTag* tag;
	Item* item;
	Block* block;
	int idk[3];
};

struct BlockGraphics {
	void** vtable; // 0
	char filler[0x20 - 8];
	int blockShape; // 32
	char filler2[40 - 36];
	float brightnessGamma; // 40
	char filler3[64 - 44];
	BlockSoundType soundType; // 64
	char filler4[0x3C0 - 68];
};

struct Vec3 {
	float x, y, z;
};

struct BlockPos {
	int x, y, z;
};

struct Color {
	float r, g, b, a;
};

// BlockSource::getBlockID は x8 経由で返すので、非トリビアルなコピーコンストラクタを持たせる
struct BlockID {
	unsigned char id;

	BlockID() : id(0) {}
	BlockID(const BlockID& other) : id(other.id) {}
};

// std::unique_ptr<T> を x8 (間接返却) で返す関数用。
// 非トリビアルなデストラクタを持たせることで x8 経由の返却になる。
struct UniquePtrResult {
	void* ptr;
	~UniquePtrResult() {}
};

// MatrixStack::push の戻り値 (x8 経由で返る)
struct MatrixStackRef {
	char* stack;
	float* matrix; // glm::mat4 (列優先)
	~MatrixStackRef() {}
};

struct ResourceLocation {
	std::string path;
	std::string fileSystem;
};

// Level::requestPlayerChangeDimension に渡すリクエスト (operator new(0x28))
struct ChangeDimensionRequest {
	int state;          // +0x00  0 = 開始
	void* unk8;         // +0x08  ServerPlayer::changeDimension では 0
	int fromDimension;  // +0x10
	int toDimension;    // +0x14
	Vec3 position;      // +0x18  移動先の座標 (usePortal == false のときそのまま使われる)
	bool usePortal;     // +0x24
	bool respawn;       // +0x25
};
static_assert(offsetof(ChangeDimensionRequest, fromDimension) == 0x10, "ChangeDimensionRequest layout");
static_assert(offsetof(ChangeDimensionRequest, position) == 0x18, "ChangeDimensionRequest layout");
static_assert(offsetof(ChangeDimensionRequest, usePortal) == 0x24, "ChangeDimensionRequest layout");
static_assert(sizeof(ChangeDimensionRequest) == 0x28, "ChangeDimensionRequest layout");

namespace Json { class Value; }

// ============================================================================
// 設定
// ============================================================================

// 0.16.2 では DimensionId 2 は未使用 (Dimension の名前テーブル上は "Undefined")
static const int MOON_DIMENSION_ID = 2;
static const int OVERWORLD_DIMENSION_ID = 0;

static const short WARP_ITEM_ID = 280;

// プレイヤーの座標は目の高さ (足元 + 1.62)
static const float PLAYER_EYE_HEIGHT = 1.62f;
static const Vec3 MOON_SPAWN_POSITION = {0.5f, 100.0f + PLAYER_EYE_HEIGHT, 0.5f};

// 月の重力 (1.62 m/s^2) / 地球の重力 (9.81 m/s^2)
static const float MOON_GRAVITY_SCALE = 1.62f / 9.81f;

// 地球の見かけの半径 (度)。バニラの太陽は約9.5度、月は約14度
static const float EARTH_ANGULAR_RADIUS = 30.0f;

static const float STAR_BRIGHTNESS = 1.0f;

static const Color MOON_SKY_COLOR = {0.0f, 0.0f, 0.0f, 1.0f}; // #000000

// 酸素が無いので月ディメンションに置けないブロック (炎, 溶岩)
static const int FIRE_BLOCK_ID = 51;
static const int FLOWING_LAVA_BLOCK_ID = 10;
static const int LAVA_BLOCK_ID = 11;

// プレイヤーが月ディメンションに居るかどうかを記録する、プレイヤーの NBT のキー
static const char* const IN_MOON_TAG_KEY = "TheMoon_InMoon";

// 月ディメンションに最後に居た座標を記録する、プレイヤーの NBT のキー (float のビット列を int で保存)
static const char* const HAS_LAST_MOON_POSITION_TAG_KEY = "TheMoon_HasLastMoonPos";
static const char* const LAST_MOON_POSITION_TAG_KEYS[3] = {"TheMoon_LastMoonPosX", "TheMoon_LastMoonPosY", "TheMoon_LastMoonPosZ"};

// ============================================================================
// 構造体 / オフセット (iOS arm64, 0.16.2)
// ============================================================================

static const size_t DIMENSION_ID_OFFSET = 192;               // Dimension::mId
static const size_t NORMAL_DIMENSION_SIZE = 0x1B0;           // Dimension::createNew の operator new サイズ
static const size_t ENTITY_DIMENSION_ID_OFFSET = 56;         // Entity::mDimensionId
static const size_t ENTITY_VELOCITY_OFFSET = 132;            // Entity::mVelocity (Vec3)
static const size_t ENTITY_ON_GROUND_OFFSET = 253;           // Entity::mOnGround
static const size_t BLOCK_SOURCE_DIMENSION_OFFSET = 40;      // BlockSource::mDimension
static const size_t PROJECTILE_COMPONENT_ENTITY_OFFSET = 16; // ProjectileComponent::mOwner (Entity*)
static const size_t PROJECTILE_COMPONENT_GRAVITY_OFFSET = 188; // ProjectileComponent::mGravity
static const size_t PLAYER_SPAWN_POSITION_OFFSET = 4748;     // Player のリスポーン地点 (BlockPos, SpawnX/Y/Z)
static const size_t LEVEL_DEFAULT_SPAWN_OFFSET = 160 + 92;   // Level::mLevelData.mSpawn (BlockPos)
static const size_t LEVEL_IS_CLIENT_SIDE_OFFSET = 5856;      // Level::isClientSide()
static const size_t ITEM_ID_OFFSET = 46;                     // Item::mId
static const size_t CHUNK_SOURCE_LEVEL_OFFSET = 16;          // ChunkSource::mLevel
static const size_t CHUNK_SOURCE_DIMENSION_OFFSET = 24;      // ChunkSource::mDimension
static const size_t FLAT_LEVEL_SOURCE_PROTOTYPE_OFFSET = 48; // FlatLevelSource の 16x16x128 ブロック雛形 (0x8000 バイト)
static const size_t LEVEL_CHUNK_MIN_OFFSET = 16;             // LevelChunk::getMin() -> BlockPos
static const size_t WEATHER_DIMENSION_OFFSET = 80;           // Weather::mDimension
static const size_t WEATHER_LEVELS_OFFSET = 44;              // 雨 (prev, cur, target) と雷 (prev, cur, target) の6つの float
static const size_t LEVEL_RENDERER_DIMENSION_OFFSET = 480;   // LevelRenderer::mDimension
static const size_t LEVEL_RENDERER_CLIENT_OFFSET = 6376;     // LevelRenderer::mClient (MinecraftClient*)
static const size_t LEVEL_RENDERER_FAR_DISTANCE_OFFSET = 6392;
static const size_t LEVEL_RENDERER_SUN_MESH_OFFSET = 6936;   // 太陽の四角形メッシュ (UV 0..1)
static const size_t LEVEL_RENDERER_BELOW_WATER_OFFSET = 8397;  // 空を *_below_water マテリアルで描くかどうか
static const size_t LEVEL_RENDERER_SUN_MATERIAL_OFFSET = 8688; // sun_moon
static const size_t LEVEL_RENDERER_SUN_MATERIAL_BELOW_WATER_OFFSET = 8728; // sun_moon_below_water
static const size_t LEVEL_RENDERER_FOG_FLAGS_OFFSET = 8396;  // byte0 = 水中, byte2 = 溶岩中
static const size_t LEVEL_RENDERER_FOG_COLOR_OFFSET = 9060;  // フォグ色 (= 画面のクリアカラー)
static const size_t MATRIX_STACK_DIRTY_OFFSET = 24;
static const size_t TEXTURE_PTR_SIZE = 64;
static const size_t MATERIAL_PTR_SIZE = 40;

static const size_t ENTITY_SET_POS_VTABLE_OFFSET = 72;           // Entity::setPos(Vec3 const&) (目の高さ)
static const size_t ENTITY_GET_POS_VTABLE_OFFSET = 0x50;         // Entity::getPos() -> Vec3 const& (目の高さ)
static const size_t ENTITY_IS_IN_WATER_VTABLE_OFFSET = 344;
static const size_t ENTITY_IS_IN_LAVA_VTABLE_OFFSET = 360;
static const size_t ENTITY_IS_IMMOBILE_VTABLE_OFFSET = 472;
static const size_t ENTITY_GET_ENTITY_TYPE_ID_VTABLE_OFFSET = 776;
static const size_t ENTITY_GET_DIMENSION_ID_VTABLE_OFFSET = 848;
static const size_t LEVEL_STORAGE_LOAD_LOCAL_PLAYER_DATA_VTABLE_OFFSET = 104; // -> std::unique_ptr<CompoundTag>
static const size_t COMPOUND_TAG_DELETING_DESTRUCTOR_VTABLE_OFFSET = 8;

static const int GENERATOR_TYPE_FLAT = 2;

// EntityType の 0x100 ビットが立っているものは Mob (プレイヤーを含む)
static const int ENTITY_TYPE_MOB_FLAG = 0x100;

// NormalDimension の vtable (アドレスポイント)。直前 16 バイトは offset-to-top と typeinfo。
static const uintptr_t NORMAL_DIMENSION_VTABLE = 0x1011649E8;
static const int DIMENSION_VTABLE_ENTRY_COUNT = 45;
static const int VTABLE_INDEX_GET_FOG_COLOR = 31;
static const int VTABLE_INDEX_MAY_RESPAWN = 35;
static const int VTABLE_INDEX_GET_TIME_OF_DAY = 44;

// ============================================================================
// ゲーム側の関数
// ============================================================================

static Item*** Item$mItems;
static Block** Block$mBlocks;
static BlockGraphics** BlockGraphics$mBlocks;

static std::unordered_map<std::string, Block*>* Block$mBlockLookupMap;

static BlockItem*(*BlockItem$BlockItem)(BlockItem*, std::string const&, int);

static ItemInstance*(*ItemInstance$ItemInstance)(ItemInstance*, int, int, int);

static void(*Item$addCreativeItem)(const ItemInstance&);

static Block*(*Block$Block)(Block*, std::string const&, int, Material const&);
static Block*(*SandBlock$SandBlock)(Block*, std::string const&, int);

static Material&(*Material$getMaterial)(MaterialType);

static BlockGraphics*(*BlockGraphics$BlockGraphics)(BlockGraphics*, std::string const&);
static void(*BlockGraphics$setCarriedTextureItem)(BlockGraphics*, std::string const&, std::string const&, std::string const&);
static void(*BlockGraphics$setTextureItem)(BlockGraphics*, std::string const&, std::string const&, std::string const&, std::string const&, std::string const&, std::string const&);

static void*(*NormalDimension$NormalDimension)(void*, void*);
static unsigned int(*Level$getSeed)(void*);
static void*(*Level$getLevelStorage)(void*);
static void(*Level$requestPlayerChangeDimension)(void*, void*, void**);
static void*(*Entity$getLevel)(void*);
static BlockSource*(*Entity$getRegion)(void*);
static BlockID(*BlockSource$getBlockID)(BlockSource*, BlockPos const&);
static bool(*BlockSource$hasChunksAt)(BlockSource*, BlockPos const&, int);
static void(*CompoundTag$putInt)(void*, std::string const&, int);
static bool(*CompoundTag$contains)(void*, std::string const&);
static int(*CompoundTag$getInt)(void*, std::string const&);

static void* MatrixStack$World;
static MatrixStackRef(*MatrixStack$push)(void*);
static void(*MatrixStackRef$destructor)(MatrixStackRef*);
static void* currentShaderColor;
static void(*ShaderColor$setColor)(void*, Color const*);
static void(*mce$Mesh$render)(void*, void*, void*, int, int);
static void*(*mce$TexturePtr$TexturePtr)(void*, void*, ResourceLocation const&);
static void* mce$RenderMaterialGroup$common;
static void*(*mce$MaterialPtr$MaterialPtr)(void*, void*, std::string const&);
static void*(*MinecraftClient$getTextures)(void*);

static void* getVirtualFunction(void* object, size_t vtableOffset) {
	void** vtable = *(void***)object;
	return vtable[vtableOffset / sizeof(void*)];
}

// Block の vtable (Block::initBlocks と同じく vtable 経由で呼ぶ)
static Block* Block$setExplodeable(Block* self, float resistance) {
	return ((Block*(*)(Block*, float))self->vtable[105])(self, resistance);
}
static Block* Block$setDestroyTime(Block* self, float time) {
	return ((Block*(*)(Block*, float))self->vtable[106])(self, time);
}

static bool Entity$isInWater(void* entity) {
	return ((bool(*)(void*))getVirtualFunction(entity, ENTITY_IS_IN_WATER_VTABLE_OFFSET))(entity);
}
static bool Entity$isInLava(void* entity) {
	return ((bool(*)(void*))getVirtualFunction(entity, ENTITY_IS_IN_LAVA_VTABLE_OFFSET))(entity);
}
static bool Entity$isImmobile(void* entity) {
	return ((bool(*)(void*))getVirtualFunction(entity, ENTITY_IS_IMMOBILE_VTABLE_OFFSET))(entity);
}
static int Entity$getEntityTypeId(void* entity) {
	return ((int(*)(void*))getVirtualFunction(entity, ENTITY_GET_ENTITY_TYPE_ID_VTABLE_OFFSET))(entity);
}
static int Entity$getDimensionId(void* entity) {
	return ((int(*)(void*))getVirtualFunction(entity, ENTITY_GET_DIMENSION_ID_VTABLE_OFFSET))(entity);
}
static const Vec3& Entity$getPos(void* entity) {
	return ((const Vec3&(*)(void*))getVirtualFunction(entity, ENTITY_GET_POS_VTABLE_OFFSET))(entity);
}
static void Entity$setPos(void* entity, Vec3 const& pos) {
	((void(*)(void*, Vec3 const&))getVirtualFunction(entity, ENTITY_SET_POS_VTABLE_OFFSET))(entity, pos);
}
static Vec3* Entity$velocity(void* entity) {
	return (Vec3*)((uintptr_t)entity + ENTITY_VELOCITY_OFFSET);
}

// 戻り値の std::unique_ptr<CompoundTag> は呼び出し側で CompoundTag$delete すること
static void* LevelStorage$loadLocalPlayerData(void* storage) {
	return ((UniquePtrResult(*)(void*))getVirtualFunction(storage, LEVEL_STORAGE_LOAD_LOCAL_PLAYER_DATA_VTABLE_OFFSET))(storage).ptr;
}
static void CompoundTag$delete(void* tag) {
	((void(*)(void*))getVirtualFunction(tag, COMPOUND_TAG_DELETING_DESTRUCTOR_VTABLE_OFFSET))(tag);
}

static bool isMoonDimension(void* dimension) {
	return dimension != nullptr && *(int*)((uintptr_t)dimension + DIMENSION_ID_OFFSET) == MOON_DIMENSION_ID;
}

static bool isInMoon(void* entity) {
	return *(int*)((uintptr_t)entity + ENTITY_DIMENSION_ID_OFFSET) == MOON_DIMENSION_ID;
}

static bool isInMoon(BlockSource* region) {
	return isMoonDimension(*(void**)((uintptr_t)region + BLOCK_SOURCE_DIMENSION_OFFSET));
}

// ============================================================================
// ブロック
// ============================================================================

// 月の砂
static const int moonSandId = 200;
static BlockItem* moonSandItemPtr;
static Block* moonSandBlockPtr;
static BlockGraphics* moonSandBlockGraphicsPtr;

// 月の石
static const int moonStoneId = 201;
static BlockItem* moonStoneItemPtr;
static Block* moonStoneBlockPtr;
static BlockGraphics* moonStoneBlockGraphicsPtr;

static const int bedrockId = 7;

// シャベルのアイテムID (木, 石, 鉄, 金, ダイヤ)
static const int shovelIds[] = {269, 273, 256, 284, 277};

// ============================================================================
// テクスチャ
// ============================================================================

static const char* const vanillaTexturePath = "minecraftpe.app/data/resourcepacks/vanilla/client/textures/";
static const char* const modTexturePath = "/Library/Application Support/themoon/themoon/textures/";

// バニラのテクスチャパスに置き換えるMODテクスチャ (textures/ 以下の相対パス)
static const char* const modTextures[] = {
	"blocks/moon_sand.png",
	"blocks/moon_stone.png",
	"environment/earth.png",
};

static const char* findModTexture(std::string const& path) {
	for(const char* texture : modTextures) {
		if(path.find(std::string(vanillaTexturePath) + texture) != std::string::npos)
			return texture;
	}
	return nullptr;
}

// sky.material に追加する地球用のマテリアル。
// 太陽の sun_moon は加算合成で星が透けるので、通常のアルファ合成にして星の上に描けるようにする
static const char* const earthMaterials =
	"\n"
	"  \"earth\": {\n"
	"    \"states\": [ \"DisableDepthWrite\", \"DisableAlphaWrite\", \"Blending\" ],\n"
	"    \"blendSrc\": \"SourceAlpha\",\n"
	"    \"blendDst\": \"OneMinusSrcAlpha\",\n"
	"    \"vertexShader\": \"shaders/uv.vertex\",\n"
	"    \"vrGeometryShader\": \"shaders/uv.geometry\",\n"
	"    \"fragmentShader\": \"shaders/texture_ccolor.fragment\",\n"
	"    \"vertexFields\": [ { \"field\": \"Position\" }, { \"field\": \"UV0\" } ],\n"
	"    \"msaaSupport\": \"MSAA\"\n"
	"  },\n"
	"\n"
	"  \"earth_below_water:earth\": {\n"
	"    \"states\": [ \"EnableStencilTest\" ],\n"
	"    \"frontFace\": { \"stencilFunc\": \"Equal\" },\n"
	"    \"backFace\": { \"stencilFunc\": \"Equal\" },\n"
	"    \"stencilRef\": 2,\n"
	"    \"stencilReadMask\": 255\n"
	"  },\n";

static uintptr_t** VTAppPlatformiOS;

static bool (*_File$exists)(std::string const&);
static bool File$exists(std::string const& path) {
	if(findModTexture(path))
		return true;

	return _File$exists(path);
}

static std::string (*_AppPlatformiOS$readAssetFile)(uintptr_t*, std::string const&);
static std::string AppPlatformiOS$readAssetFile(uintptr_t* self, std::string const& str) {

	if(const char* texture = findModTexture(str))
		return _AppPlatformiOS$readAssetFile(self, std::string(modTexturePath) + texture);

	std::string content = _AppPlatformiOS$readAssetFile(self, str);
	if (strstr(str.c_str(), "minecraftpe.app/data/resourcepacks/vanilla/client/materials/sky.material")) {
		size_t objectStart = content.find('{');
		if(objectStart != std::string::npos)
			content.insert(objectStart + 1, earthMaterials);
	}
	else if (strstr(str.c_str(), "minecraftpe.app/data/resourcepacks/vanilla/client/textures/terrain_texture.json")) {
		NSString *jsonString = [NSString stringWithUTF8String:content.c_str()];
		NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
		NSError *jsonError;
		NSMutableDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:&jsonError];

		NSMutableDictionary *jsonTextureData = [jsonDict objectForKey:@"texture_data"];
		[jsonTextureData setObject:@{
			@"textures": @[@"textures/blocks/moon_sand"]
		} forKey:@"moon_sand"];
		[jsonTextureData setObject:@{
			@"textures": @[@"textures/blocks/moon_stone"]
		} forKey:@"moon_stone"];

		jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict options:NSJSONWritingPrettyPrinted error:&jsonError];
		jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
		content = std::string([jsonString UTF8String]);
	}
	else if (strstr(str.c_str(), "minecraftpe.app/data/resourcepacks/vanilla/client/texts/ja_JP.lang")) {
		content += "\ntile.moon_sand.default.name=月の砂\t#\n";
		content += "tile.moon_sand.name=月の砂\t#\n";
		content += "tile.moon_stone.name=月の石\t#\n";
	}
	else if (strstr(str.c_str(), "minecraftpe.app/data/resourcepacks/vanilla/client/texts/") && strstr(str.c_str(), ".lang")) {
		content += "\ntile.moon_sand.default.name=Moon Sand\n";
		content += "tile.moon_sand.name=Moon Sand\n";
		content += "tile.moon_stone.name=Moon Stone\n";
	}
	return content;
}

// ============================================================================
// フック: ブロックとアイテムの登録
// ============================================================================

static void (*_Item$initCreativeItems)();
static void Item$initCreativeItems() {
	_Item$initCreativeItems();

	ItemInstance moonSandInst;
	ItemInstance$ItemInstance(&moonSandInst, moonSandId, 1, 0);
	Item$addCreativeItem(moonSandInst);

	ItemInstance moonStoneInst;
	ItemInstance$ItemInstance(&moonStoneInst, moonStoneId, 1, 0);
	Item$addCreativeItem(moonStoneInst);
}

static void (*_Item$addBlockItems)();
static void Item$addBlockItems() {
	_Item$addBlockItems();

	if(!moonSandItemPtr) {
		moonSandItemPtr = new BlockItem();
		BlockItem$BlockItem(moonSandItemPtr, "moon_sand", moonSandId - 0x100);
	}
	Item$mItems[1][moonSandId] = moonSandItemPtr;

	if(!moonStoneItemPtr) {
		moonStoneItemPtr = new BlockItem();
		BlockItem$BlockItem(moonStoneItemPtr, "moon_stone", moonStoneId - 0x100);
	}
	Item$mItems[1][moonStoneId] = moonStoneItemPtr;
}

static void (*_Item$registerItems)();
static void Item$registerItems() {
	_Item$registerItems();

	// 月の砂をバニラの砂と同じくシャベルの適正ブロックにする
	// (月の石は材質が石なのでツルハシが材質で判定する)
	for(int shovelId : shovelIds) {
		Item* shovel = Item$mItems[1][shovelId];
		if(shovel)
			DiggerItem$effectiveBlocks(shovel)[moonSandId] = true;
	}
}

static void (*_Block$initBlocks)();
static void Block$initBlocks() {
	_Block$initBlocks();

	// SandBlock (HeavyBlock) なので下にブロックが無いと落下する。材質はSandBlock内で砂(14)
	moonSandBlockPtr = new Block();
	SandBlock$SandBlock(moonSandBlockPtr, "moon_sand", moonSandId);
	Block$mBlocks[moonSandId] = moonSandBlockPtr;
	(*Block$mBlockLookupMap)["moon_sand"] = moonSandBlockPtr;
	Block$setDestroyTime(moonSandBlockPtr, 0.5f); // バニラの砂と同じ
	moonSandBlockPtr->category = 1;

	moonStoneBlockPtr = new Block();
	Block$Block(moonStoneBlockPtr, "moon_stone", moonStoneId, Material$getMaterial(MaterialType::STONE));
	Block$mBlocks[moonStoneId] = moonStoneBlockPtr;
	(*Block$mBlockLookupMap)["moon_stone"] = moonStoneBlockPtr;
	Block$setDestroyTime(moonStoneBlockPtr, 1.5f); // バニラの石と同じ
	Block$setExplodeable(moonStoneBlockPtr, 10.0f);
	moonStoneBlockPtr->category = 1;
}

static void (*_BlockGraphics$initBlocks)();
static void BlockGraphics$initBlocks() {
	_BlockGraphics$initBlocks();

	moonSandBlockGraphicsPtr = new BlockGraphics();
	BlockGraphics$BlockGraphics(moonSandBlockGraphicsPtr, "moon_sand");
	BlockGraphics$mBlocks[moonSandId] = moonSandBlockGraphicsPtr;
	moonSandBlockGraphicsPtr->brightnessGamma = 0.55f; // blocks.json の砂と同じ
	moonSandBlockGraphicsPtr->soundType = BlockSoundType::SAND;
	BlockGraphics$setCarriedTextureItem(moonSandBlockGraphicsPtr, "moon_sand", "moon_sand", "moon_sand");
	BlockGraphics$setTextureItem(moonSandBlockGraphicsPtr, "moon_sand", "moon_sand", "moon_sand", "moon_sand", "moon_sand", "moon_sand");

	moonStoneBlockGraphicsPtr = new BlockGraphics();
	BlockGraphics$BlockGraphics(moonStoneBlockGraphicsPtr, "moon_stone");
	BlockGraphics$mBlocks[moonStoneId] = moonStoneBlockGraphicsPtr;
	moonStoneBlockGraphicsPtr->soundType = BlockSoundType::STONE;
	BlockGraphics$setCarriedTextureItem(moonStoneBlockGraphicsPtr, "moon_stone", "moon_stone", "moon_stone");
	BlockGraphics$setTextureItem(moonStoneBlockGraphicsPtr, "moon_stone", "moon_stone", "moon_stone", "moon_stone", "moon_stone", "moon_stone");
}

// ============================================================================
// 月ディメンション専用の vtable
// mayRespawn などは 8 バイトしかない関数で MSHookFunction では隣の関数を壊すため、
// NormalDimension の vtable を複製して月ディメンションのオブジェクトだけ差し替える。
// ============================================================================

static void* moonDimensionVtable[2 + DIMENSION_VTABLE_ENTRY_COUNT];
static bool moonDimensionVtableReady = false;

static Color MoonDimension$getFogColor(void* self, float brightness) {
	return MOON_SKY_COLOR;
}

// false にすると、ネザーと同じくベッドで寝ようとしたときに爆発する
static bool MoonDimension$mayRespawn(void* self) {
	return false;
}

// 常に 0 (正午) にして、空の明るさを一定にし、太陽の角度で星が回らないようにする
static float MoonDimension$getTimeOfDay(void* self, int time, float partialTicks) {
	return 0.0f;
}

static void** getMoonDimensionVtable() {
	if(!moonDimensionVtableReady) {
		void** normalDimensionVtable = (void**)(NORMAL_DIMENSION_VTABLE + _dyld_get_image_vmaddr_slide(0));
		memcpy(moonDimensionVtable, normalDimensionVtable - 2, sizeof(moonDimensionVtable));
		moonDimensionVtable[2 + VTABLE_INDEX_GET_FOG_COLOR] = (void*)&MoonDimension$getFogColor;
		moonDimensionVtable[2 + VTABLE_INDEX_MAY_RESPAWN] = (void*)&MoonDimension$mayRespawn;
		moonDimensionVtable[2 + VTABLE_INDEX_GET_TIME_OF_DAY] = (void*)&MoonDimension$getTimeOfDay;
		moonDimensionVtableReady = true;
	}
	return &moonDimensionVtable[2];
}

// ============================================================================
// フック: ディメンションの生成
// ============================================================================

static bool creatingMoonDimension = false;

// Dimension::Dimension(Level&, DimensionId, short height)
static void* (*_Dimension$Dimension)(void*, void*, int, short);
static void* Dimension$Dimension(void* self, void* level, int dimensionId, short height) {
	// NormalDimension のコンストラクタは ID 0 固定で基底を呼ぶので、月ディメンション生成中だけ差し替える
	if(creatingMoonDimension)
		dimensionId = MOON_DIMENSION_ID;
	return _Dimension$Dimension(self, level, dimensionId, height);
}

// static std::unique_ptr<Dimension> Dimension::createNew(DimensionId, Level&)
static UniquePtrResult (*_Dimension$createNew)(int, void*);
static UniquePtrResult Dimension$createNew(int dimensionId, void* level) {
	if(dimensionId != MOON_DIMENSION_ID)
		return _Dimension$createNew(dimensionId, level);

	void* dimension = ::operator new(NORMAL_DIMENSION_SIZE);
	creatingMoonDimension = true;
	NormalDimension$NormalDimension(dimension, level);
	creatingMoonDimension = false;
	*(void***)dimension = getMoonDimensionVtable();

	UniquePtrResult result;
	result.ptr = dimension;
	return result;
}

// ============================================================================
// フック: 地形生成
// ============================================================================

struct CraterType {
	float diameter;
	float depth;
	float rimHeight;
	int weight; // 出現しやすさ
};

// 4段階のクレーター (直径 4, 5, 7, 12 ブロック)
static const CraterType craterTypes[] = {
	{4.0f, 1.5f, 0.0f, 40},
	{5.0f, 2.0f, 0.0f, 30},
	{7.0f, 3.0f, 1.0f, 20},
	{12.0f, 4.5f, 1.0f, 10},
};
static const int CRATER_CELL_SIZE = 18;       // この大きさの区画ごとに最大1個
static const int CRATER_CHANCE_PERCENT = 60;  // 区画にクレーターがある確率
static const int CRATER_MAX_REACH = 9;        // 中心から影響が届く最大距離 (半径 + 縁)

static const int SURFACE_BASE_HEIGHT = 62;
static const int MOON_SAND_DEPTH = 4;          // バニラの草 + 土と同じく表面から4ブロック

static uint32_t hashInts(int a, int b, int c, uint32_t seed) {
	uint32_t h = seed ^ 0x9E3779B9u;
	h ^= (uint32_t)a * 0x8DA6B343u;
	h = (h << 13) | (h >> 19);
	h ^= (uint32_t)b * 0xD8163841u;
	h = (h << 13) | (h >> 19);
	h ^= (uint32_t)c * 0xCB1AB31Fu;
	h ^= h >> 16;
	h *= 0x85EBCA6Bu;
	h ^= h >> 13;
	h *= 0xC2B2AE35u;
	h ^= h >> 16;
	return h;
}

// -1..1 のなめらかなノイズ
static float valueNoise(float x, float z, uint32_t seed) {
	int x0 = (int)floorf(x);
	int z0 = (int)floorf(z);
	float fx = x - x0;
	float fz = z - z0;
	fx = fx * fx * (3.0f - 2.0f * fx);
	fz = fz * fz * (3.0f - 2.0f * fz);

	auto corner = [&](int cx, int cz) {
		return (hashInts(cx, cz, 0, seed) & 0xFFFF) / 32767.5f - 1.0f;
	};
	float top = corner(x0, z0) + (corner(x0 + 1, z0) - corner(x0, z0)) * fx;
	float bottom = corner(x0, z0 + 1) + (corner(x0 + 1, z0 + 1) - corner(x0, z0 + 1)) * fx;
	return top + (bottom - top) * fz;
}

// オーバーワールドより緩やかな起伏 (±5ブロック程度)
static float baseSurfaceHeight(int x, int z, uint32_t seed) {
	return SURFACE_BASE_HEIGHT
		+ 3.5f * valueNoise(x / 48.0f, z / 48.0f, seed)
		+ 1.5f * valueNoise(x / 14.0f, z / 14.0f, seed + 1);
}

struct Crater {
	float centerX, centerZ;
	const CraterType* type;
};

static bool craterInCell(int cellX, int cellZ, uint32_t seed, Crater& crater) {
	uint32_t h = hashInts(cellX, cellZ, 0x4352, seed);
	if((int)(h % 100) >= CRATER_CHANCE_PERCENT)
		return false;

	uint32_t h2 = hashInts(cellX, cellZ, 0x5459, seed);
	int totalWeight = 0;
	for(const CraterType& type : craterTypes)
		totalWeight += type.weight;
	int pick = (int)(h2 % totalWeight);
	crater.type = &craterTypes[0];
	for(const CraterType& type : craterTypes) {
		if(pick < type.weight) {
			crater.type = &type;
			break;
		}
		pick -= type.weight;
	}

	// 直径が偶数ならブロックの角、奇数ならブロックの中心をクレーターの中心にする
	float centerOffset = ((int)crater.type->diameter % 2 == 0) ? 0.0f : 0.5f;
	crater.centerX = cellX * CRATER_CELL_SIZE + (int)((h >> 8) % CRATER_CELL_SIZE) + centerOffset;
	crater.centerZ = cellZ * CRATER_CELL_SIZE + (int)((h >> 16) % CRATER_CELL_SIZE) + centerOffset;
	return true;
}

static float craterHeightOffset(Crater const& crater, int x, int z) {
	float dx = x + 0.5f - crater.centerX;
	float dz = z + 0.5f - crater.centerZ;
	float distance = sqrtf(dx * dx + dz * dz);
	float radius = crater.type->diameter / 2.0f;

	if(distance < radius) {
		float t = distance / radius;
		return -crater.type->depth * (1.0f - t * t);
	}

	float rimWidth = fmaxf(1.0f, radius * 0.4f);
	if(crater.type->rimHeight > 0.0f && distance < radius + rimWidth)
		return crater.type->rimHeight * (1.0f - (distance - radius) / rimWidth);

	return 0.0f;
}

static void generateMoonChunk(uint8_t* blocks, int minX, int minZ, uint32_t seed) {
	std::vector<Crater> craters;
	int firstCellX = (int)floorf((minX - CRATER_MAX_REACH) / (float)CRATER_CELL_SIZE);
	int lastCellX = (int)floorf((minX + 15 + CRATER_MAX_REACH) / (float)CRATER_CELL_SIZE);
	int firstCellZ = (int)floorf((minZ - CRATER_MAX_REACH) / (float)CRATER_CELL_SIZE);
	int lastCellZ = (int)floorf((minZ + 15 + CRATER_MAX_REACH) / (float)CRATER_CELL_SIZE);
	for(int cellX = firstCellX; cellX <= lastCellX; cellX++) {
		for(int cellZ = firstCellZ; cellZ <= lastCellZ; cellZ++) {
			Crater crater;
			if(craterInCell(cellX, cellZ, seed, crater))
				craters.push_back(crater);
		}
	}

	for(int x = 0; x < 16; x++) {
		for(int z = 0; z < 16; z++) {
			int worldX = minX + x;
			int worldZ = minZ + z;

			float height = baseSurfaceHeight(worldX, worldZ, seed);
			for(Crater const& crater : craters)
				height += craterHeightOffset(crater, worldX, worldZ);
			int surface = (int)floorf(height + 0.5f);
			if(surface < 8)
				surface = 8;
			if(surface > 120)
				surface = 120;

			// ブロック配列のインデックスは (x << 11) | (z << 7) | y
			uint8_t* column = blocks + ((x << 11) | (z << 7));
			for(int y = 0; y < 128; y++) {
				uint8_t id = 0;
				if(y == 0)
					id = bedrockId;
				else if(y <= 4 && (int)(hashInts(worldX, y, worldZ, seed ^ 0xBEDu) % 5) >= y)
					id = bedrockId; // バニラと同じく y = 1..4 にまばらな岩盤
				else if(y <= surface - MOON_SAND_DEPTH)
					id = moonStoneId;
				else if(y <= surface)
					id = moonSandId;
				column[y] = id;
			}
		}
	}
}

// std::unique_ptr<ChunkSource> Dimension::_createGenerator(GeneratorType)
static UniquePtrResult (*_Dimension$_createGenerator)(void*, int);
static UniquePtrResult Dimension$_createGenerator(void* self, int generatorType) {
	if(!isMoonDimension(self))
		return _Dimension$_createGenerator(self, generatorType);

	// FlatLevelSource を使い、loadChunk でブロックの雛形を月の地形に書き換える
	return _Dimension$_createGenerator(self, GENERATOR_TYPE_FLAT);
}

// チャンク生成は複数スレッドから呼ばれるので、雛形の書き換えから読み込み完了までを排他する
static pthread_mutex_t moonGeneratorMutex = PTHREAD_MUTEX_INITIALIZER;

// void FlatLevelSource::loadChunk(LevelChunk&)
static uintptr_t (*_FlatLevelSource$loadChunk)(void*, void*);
static uintptr_t FlatLevelSource$loadChunk(void* self, void* chunk) {
	void* dimension = *(void**)((uintptr_t)self + CHUNK_SOURCE_DIMENSION_OFFSET);
	if(!isMoonDimension(dimension))
		return _FlatLevelSource$loadChunk(self, chunk);

	void* level = *(void**)((uintptr_t)self + CHUNK_SOURCE_LEVEL_OFFSET);
	const BlockPos* chunkMin = (const BlockPos*)((uintptr_t)chunk + LEVEL_CHUNK_MIN_OFFSET);
	uint8_t* prototype = (uint8_t*)((uintptr_t)self + FLAT_LEVEL_SOURCE_PROTOTYPE_OFFSET);

	pthread_mutex_lock(&moonGeneratorMutex);
	generateMoonChunk(prototype, chunkMin->x, chunkMin->z, Level$getSeed(level));
	// 元の処理が雛形をチャンクにコピーし、ハイトマップの計算などを行う
	uintptr_t result = _FlatLevelSource$loadChunk(self, chunk);
	pthread_mutex_unlock(&moonGeneratorMutex);
	return result;
}

// ============================================================================
// フック: アイテム ID 280 で地面をタップしたら月へワープ / オーバーワールドのリスポーン地点へ帰還
// ============================================================================

static std::chrono::steady_clock::time_point lastWarpTime;
static const auto WARP_COOLDOWN = std::chrono::milliseconds(1500);

// オーバーワールドに帰還したあと、地形が読み込まれてから安全な高さに置き直すプレイヤー
static void* pendingReturnPlayer = nullptr;
static int pendingReturnTicks = 0;
static const int PENDING_RETURN_TIMEOUT_TICKS = 20 * 30;

static void requestChangeDimension(void* level, void* player, int fromDimension, int toDimension, Vec3 const& position) {
	ChangeDimensionRequest* request = new ChangeDimensionRequest();
	request->state = 0;
	request->unk8 = nullptr;
	request->fromDimension = fromDimension;
	request->toDimension = toDimension;
	request->position = position;
	request->usePortal = false; // true だとネザーポータルが作られてしまう
	request->respawn = false;

	// std::unique_ptr<ChangeDimensionRequest> の値渡し (所有権はゲーム側に移る)
	void* requestHolder = request;
	Level$requestPlayerChangeDimension(level, player, &requestHolder);
	if(requestHolder != nullptr)
		delete (ChangeDimensionRequest*)requestHolder;
}

// 月ディメンションで最後に地面に立っていた座標 (目の高さ)。プレイヤーの NBT に保存する
static std::unordered_map<void*, Vec3> lastMoonPositions;

static const int PLAYER_ENTITY_TYPE_ID = 319;

static bool isPlayer(void* entity) {
	return Entity$getEntityTypeId(entity) == PLAYER_ENTITY_TYPE_ID;
}

static void recordLastMoonPosition(void* player) {
	const Vec3& pos = Entity$getPos(player);
	if(pos.y - PLAYER_EYE_HEIGHT > 0.0f)
		lastMoonPositions[player] = pos;
}

// 初めて行くときは x0 y100 z0、それ以降は最後に居た座標
static Vec3 getMoonArrivalPosition(void* player) {
	auto it = lastMoonPositions.find(player);
	if(it != lastMoonPositions.end())
		return it->second;
	return MOON_SPAWN_POSITION;
}

// オーバーワールドのリスポーン地点 (ベッドで寝た場所があればそこ、なければワールドのスポーン地点)
static BlockPos getOverworldRespawnPosition(void* player, void* level) {
	BlockPos spawn = *(BlockPos*)((uintptr_t)player + PLAYER_SPAWN_POSITION_OFFSET);
	if(spawn.y < 0)
		spawn = *(BlockPos*)((uintptr_t)level + LEVEL_DEFAULT_SPAWN_OFFSET);
	return spawn;
}

static bool handleWarpItem(void* player) {
	void* level = Entity$getLevel(player);
	if(level == nullptr || *(bool*)((uintptr_t)level + LEVEL_IS_CLIENT_SIDE_OFFSET))
		return false;

	auto now = std::chrono::steady_clock::now();
	if(now - lastWarpTime < WARP_COOLDOWN)
		return true;
	lastWarpTime = now;

	int currentDimension = Entity$getDimensionId(player);

	if(currentDimension == MOON_DIMENSION_ID) {
		recordLastMoonPosition(player);
		BlockPos spawn = getOverworldRespawnPosition(player, level);
		Vec3 position = {spawn.x + 0.5f, spawn.y + PLAYER_EYE_HEIGHT, spawn.z + 0.5f};
		requestChangeDimension(level, player, currentDimension, OVERWORLD_DIMENSION_ID, position);
		pendingReturnPlayer = player;
		pendingReturnTicks = 0;
		return true;
	}

	requestChangeDimension(level, player, currentDimension, MOON_DIMENSION_ID, getMoonArrivalPosition(player));
	return true;
}

// リスポーン地点の高さはブロックの中や空中のことがあるので、足元と頭が空気で、足の下が地面になる高さを探す
static void placeReturnedPlayerSafely(void* player) {
	BlockSource* region = Entity$getRegion(player);
	if(region == nullptr)
		return;

	const Vec3& pos = Entity$getPos(player);
	BlockPos feet = {(int)floorf(pos.x), (int)floorf(pos.y - PLAYER_EYE_HEIGHT), (int)floorf(pos.z)};
	if(!BlockSource$hasChunksAt(region, feet, 1))
		return;

	auto isAir = [&](int y) {
		return BlockSource$getBlockID(region, BlockPos({feet.x, y, feet.z})).id == 0;
	};

	int y = feet.y;
	if(y < 1)
		y = 1;
	if(y > 126)
		y = 126;
	while(y < 126 && (!isAir(y) || !isAir(y + 1)))
		y++;
	while(y > 1 && isAir(y - 1))
		y--;

	Entity$setPos(player, Vec3({pos.x, y + PLAYER_EYE_HEIGHT, pos.z}));
	pendingReturnPlayer = nullptr;
}

// bool Item::useOn(ItemInstance*, Player*, int, int, int, signed char, float, float, float)
static bool (*_Item$useOn)(void*, void*, void*, int, int, int, signed char, float, float, float);
static bool Item$useOn(void* self, void* itemInstance, void* player, int x, int y, int z, signed char face, float hitX, float hitY, float hitZ) {
	if(player != nullptr && *(short*)((uintptr_t)self + ITEM_ID_OFFSET) == WARP_ITEM_ID) {
		if(handleWarpItem(player))
			return true;
	}
	return _Item$useOn(self, itemInstance, player, x, y, z, face, hitX, hitY, hitZ);
}

// ============================================================================
// フック: 月ディメンションに居る状態の保存と読み込み
// ゲーム本体は保存された DimensionId が 2 以上だとオーバーワールド (0) に戻してしまうため
// (Level::loadPlayer と Player::readAdditionalSaveData)、独自のキーで記録して読み込み時に差し替える
// ============================================================================

// Level::loadPlayer 中に、オーバーワールドの代わりに月ディメンションを作らせるためのフラグ
static bool loadingPlayerIntoMoon = false;
static bool playerLoadedIntoMoon = false;

static bool isInMoonTag(void* tag) {
	std::string key(IN_MOON_TAG_KEY);
	return tag != nullptr && CompoundTag$contains(tag, key) && CompoundTag$getInt(tag, key) != 0;
}

// void Player::addAdditionalSaveData(CompoundTag&)
static void (*_Player$addAdditionalSaveData)(void*, void*);
static void Player$addAdditionalSaveData(void* self, void* tag) {
	_Player$addAdditionalSaveData(self, tag);
	CompoundTag$putInt(tag, IN_MOON_TAG_KEY, Entity$getDimensionId(self) == MOON_DIMENSION_ID ? 1 : 0);

	auto it = lastMoonPositions.find(self);
	CompoundTag$putInt(tag, HAS_LAST_MOON_POSITION_TAG_KEY, it != lastMoonPositions.end() ? 1 : 0);
	if(it != lastMoonPositions.end()) {
		const float* position = &it->second.x;
		for(int i = 0; i < 3; i++) {
			int bits;
			memcpy(&bits, &position[i], sizeof(bits));
			CompoundTag$putInt(tag, LAST_MOON_POSITION_TAG_KEYS[i], bits);
		}
	}
}

// void Player::readAdditionalSaveData(CompoundTag const&)
static void (*_Player$readAdditionalSaveData)(void*, void*);
static void Player$readAdditionalSaveData(void* self, void* tag) {
	_Player$readAdditionalSaveData(self, tag);
	// 元の処理は DimensionId が 2 以上だと無視するので、月ディメンションに読み込んだときはここで設定する
	if(playerLoadedIntoMoon)
		*(int*)((uintptr_t)self + ENTITY_DIMENSION_ID_OFFSET) = MOON_DIMENSION_ID;

	lastMoonPositions.erase(self);
	std::string hasKey(HAS_LAST_MOON_POSITION_TAG_KEY);
	if(CompoundTag$contains(tag, hasKey) && CompoundTag$getInt(tag, hasKey) != 0) {
		Vec3 position;
		float* components = &position.x;
		for(int i = 0; i < 3; i++) {
			int bits = CompoundTag$getInt(tag, LAST_MOON_POSITION_TAG_KEYS[i]);
			memcpy(&components[i], &bits, sizeof(bits));
		}
		lastMoonPositions[self] = position;
	}
}

// Dimension* Level::createDimension(DimensionId)
static void* (*_Level$createDimension)(void*, int);
static void* Level$createDimension(void* self, int dimensionId) {
	if(loadingPlayerIntoMoon && dimensionId == OVERWORLD_DIMENSION_ID) {
		loadingPlayerIntoMoon = false;
		playerLoadedIntoMoon = true;
		dimensionId = MOON_DIMENSION_ID;
	}
	return _Level$createDimension(self, dimensionId);
}

// void Level::loadPlayer(std::unique_ptr<Player>)
static void (*_Level$loadPlayer)(void*, void**);
static void Level$loadPlayer(void* self, void** player) {
	// 別のワールドのプレイヤーが同じアドレスに作られることがあるので、前のワールドの記録を消す
	lastMoonPositions.clear();

	// 元の処理と同じ方法で保存済みのプレイヤーデータを先に読み、月ディメンションに居たかを調べる
	void* storage = Level$getLevelStorage(self);
	if(storage != nullptr) {
		void* tag = LevelStorage$loadLocalPlayerData(storage);
		if(tag != nullptr) {
			loadingPlayerIntoMoon = isInMoonTag(tag);
			CompoundTag$delete(tag);
		}
	}

	_Level$loadPlayer(self, player);

	loadingPlayerIntoMoon = false;
	playerLoadedIntoMoon = false;
}

// ============================================================================
// フック: 重力
// ============================================================================

// Mob (プレイヤーを含む) は Mob::travel の最後で vy = (vy - 0.08) * 0.98 される
static const float MOB_GRAVITY = 0.08f;
static const float MOB_AIR_DRAG = 0.98f;

// Mob 以外で Entity::move(mVelocity) の前に重力を引くエンティティ (EntityType の下位8ビット → 重力)
static float nonMobGravity(int entityTypeId) {
	switch(entityTypeId & 0xFF) {
		case 64: // ItemEntity
		case 65: // PrimedTnt
		case 66: // FallingBlock
		case 84: // Minecart
		case 96: // MinecartHopper
		case 97: // MinecartTNT
		case 98: // MinecartChest
			return 0.04f;
		case 69: // ExperienceOrb
			return 0.03f;
		default:
			return 0.0f;
	}
}

// void Mob::travel(float, float)
static void (*_Mob$travel)(void*, float, float);
static void Mob$travel(void* self, float strafe, float forward) {
	if(self == pendingReturnPlayer) {
		if(Entity$getDimensionId(self) == OVERWORLD_DIMENSION_ID)
			placeReturnedPlayerSafely(self);
		if(++pendingReturnTicks > PENDING_RETURN_TIMEOUT_TICKS)
			pendingReturnPlayer = nullptr;
	}

	// 奈落に落ちた位置などを記録しないよう、地面に立っているときだけ記録する
	if(isInMoon(self) && *(bool*)((uintptr_t)self + ENTITY_ON_GROUND_OFFSET) && isPlayer(self))
		recordLastMoonPosition(self);

	// 水中・溶岩中・動けない状態では重力の計算が違うので補正しない
	bool applyMoonGravity = isInMoon(self) && !Entity$isImmobile(self) && !Entity$isInWater(self) && !Entity$isInLava(self);

	_Mob$travel(self, strafe, forward);

	// 引かれた重力のうち、月の重力を超える分を戻す
	// (飛行中のプレイヤーは Player::travel が元の速度に戻すので影響しない)
	if(applyMoonGravity)
		Entity$velocity(self)->y += MOB_GRAVITY * MOB_AIR_DRAG * (1.0f - MOON_GRAVITY_SCALE);
}

// void Entity::move(Vec3 const&)
static void (*_Entity$move)(void*, Vec3 const&);
static void Entity$move(void* self, Vec3 const& delta) {
	// 自分の速度で移動するときだけ (押し出しなどは除く)
	if(&delta == Entity$velocity(self) && isInMoon(self)) {
		int entityTypeId = Entity$getEntityTypeId(self);
		if((entityTypeId & ENTITY_TYPE_MOB_FLAG) == 0 && !Entity$isInWater(self) && !Entity$isInLava(self)) {
			float gravity = nonMobGravity(entityTypeId);
			if(gravity > 0.0f)
				Entity$velocity(self)->y += gravity * (1.0f - MOON_GRAVITY_SCALE);
		}
	}
	_Entity$move(self, delta);
}

// void Mob::causeFallDamage(float)
static void (*_Mob$causeFallDamage)(void*, float);
static void Mob$causeFallDamage(void* self, float distance) {
	// 月の重力では、同じ高さから落ちても着地の速さは地球で 1/6 の高さから落ちたときと同じ
	if(isInMoon(self))
		distance *= MOON_GRAVITY_SCALE;
	_Mob$causeFallDamage(self, distance);
}

// void ProjectileComponent::tick()
// 矢・雪玉・卵・ポーションなどは、この中で vy -= mGravity される
static void (*_ProjectileComponent$tick)(void*);
static void ProjectileComponent$tick(void* self) {
	void* entity = *(void**)((uintptr_t)self + PROJECTILE_COMPONENT_ENTITY_OFFSET);
	if(entity == nullptr || !isInMoon(entity)) {
		_ProjectileComponent$tick(self);
		return;
	}

	float* gravity = (float*)((uintptr_t)self + PROJECTILE_COMPONENT_GRAVITY_OFFSET);
	float originalGravity = *gravity;
	*gravity = originalGravity * MOON_GRAVITY_SCALE;
	_ProjectileComponent$tick(self);
	*gravity = originalGravity;
}

// ============================================================================
// フック: 酸素が無いので月では炎と溶岩を置けない
// 火打石・ファイヤーチャージ・溶岩バケツ・ディスペンサー・ベッドの爆発など、
// ブロックの設置はすべて BlockSource::setBlockAndData を通る
// ============================================================================

static bool isMoonForbiddenBlock(int blockId) {
	return blockId == FIRE_BLOCK_ID || blockId == FLOWING_LAVA_BLOCK_ID || blockId == LAVA_BLOCK_ID;
}

// bool BlockSource::setBlockAndData(BlockPos const&, FullBlock, int, std::unique_ptr<BlockEntity>)
static bool (*_BlockSource$setBlockAndData)(BlockSource*, BlockPos const&, uint8_t const*, int, void*);
static bool BlockSource$setBlockAndData(BlockSource* self, BlockPos const& pos, uint8_t const* fullBlock, int updateFlags, void* blockEntity) {
	if(isMoonForbiddenBlock(fullBlock[0]) && isInMoon(self))
		return false;
	return _BlockSource$setBlockAndData(self, pos, fullBlock, updateFlags, blockEntity);
}

// bool BucketItem::_emptyBucket(BlockSource&, FullBlock const&, BlockPos const&)
// 元の処理は設置に失敗してもバケツを空にしてしまうので、溶岩バケツは使えないようにする
static bool (*_BucketItem$_emptyBucket)(void*, BlockSource*, uint8_t const*, BlockPos const&);
static bool BucketItem$_emptyBucket(void* self, BlockSource* region, uint8_t const* fullBlock, BlockPos const& pos) {
	if(isMoonForbiddenBlock(fullBlock[0]) && isInMoon(region))
		return false;
	return _BucketItem$_emptyBucket(self, region, fullBlock, pos);
}

// ============================================================================
// フック: 天気 (月では雨も雷も無し)
// ============================================================================

// void Weather::tick()
static uintptr_t (*_Weather$tick)(void*);
static uintptr_t Weather$tick(void* self) {
	uintptr_t result = _Weather$tick(self);
	if(isMoonDimension(*(void**)((uintptr_t)self + WEATHER_DIMENSION_OFFSET)))
		memset((void*)((uintptr_t)self + WEATHER_LEVELS_OFFSET), 0, sizeof(float) * 6);
	return result;
}

// ============================================================================
// フック: 描画 (空・星・地球・雲・フォグ)
// ============================================================================

static void* levelRendererDimension(void* levelRenderer) {
	return *(void**)((uintptr_t)levelRenderer + LEVEL_RENDERER_DIMENSION_OFFSET);
}

// Color Dimension::getSkyColor(Entity const&, float)
static Color (*_Dimension$getSkyColor)(void*, void*, float);
static Color Dimension$getSkyColor(void* self, void* entity, float partialTicks) {
	if(isMoonDimension(self))
		return MOON_SKY_COLOR;
	return _Dimension$getSkyColor(self, entity, partialTicks);
}

// float Dimension::getStarBrightness(float)
static float (*_Dimension$getStarBrightness)(void*, float);
static float Dimension$getStarBrightness(void* self, float partialTicks) {
	if(isMoonDimension(self))
		return STAR_BRIGHTNESS;
	return _Dimension$getStarBrightness(self, partialTicks);
}

alignas(16) static char earthTexturePtr[TEXTURE_PTR_SIZE];
static bool earthTextureReady = false;

static void* getEarthTexture(void* levelRenderer) {
	if(!earthTextureReady) {
		void* client = *(void**)((uintptr_t)levelRenderer + LEVEL_RENDERER_CLIENT_OFFSET);
		ResourceLocation location;
		location.path = "textures/environment/earth";
		location.fileSystem = "InUserPackage";
		mce$TexturePtr$TexturePtr(earthTexturePtr, MinecraftClient$getTextures(client), location);
		earthTextureReady = true;
	}
	return earthTexturePtr;
}

// sky.material に追加した earth / earth_below_water の MaterialPtr。
// MaterialPtr はマテリアルの再読み込みのために自身のアドレスをグループに登録するので、移動させない
alignas(16) static char earthMaterialPtr[MATERIAL_PTR_SIZE];
alignas(16) static char earthBelowWaterMaterialPtr[MATERIAL_PTR_SIZE];
static bool earthMaterialsReady = false;

static const size_t MATERIAL_PTR_MATERIAL_OFFSET = 8; // MaterialPtr::mRenderMaterial

static void* getEarthMaterial(void* levelRenderer) {
	if(!earthMaterialsReady) {
		mce$MaterialPtr$MaterialPtr(earthMaterialPtr, mce$RenderMaterialGroup$common, "earth");
		mce$MaterialPtr$MaterialPtr(earthBelowWaterMaterialPtr, mce$RenderMaterialGroup$common, "earth_below_water");
		earthMaterialsReady = true;
	}

	bool belowWater = *(bool*)((uintptr_t)levelRenderer + LEVEL_RENDERER_BELOW_WATER_OFFSET);
	char* material = belowWater ? earthBelowWaterMaterialPtr : earthMaterialPtr;
	// sky.material の書き換えが反映されていないときは、太陽のマテリアルで描く
	if(*(void**)(material + MATERIAL_PTR_MATERIAL_OFFSET) == nullptr)
		return (void*)((uintptr_t)levelRenderer + (belowWater ? LEVEL_RENDERER_SUN_MATERIAL_BELOW_WATER_OFFSET : LEVEL_RENDERER_SUN_MATERIAL_OFFSET));
	return material;
}

// 太陽と同じ四角形メッシュで、地平線 (仰角0度) に中心が来るように地球を描く。
// 星の後にアルファ合成で描くので、星が地球に重ならない
static void renderEarth(void* levelRenderer) {
	uintptr_t renderer = (uintptr_t)levelRenderer;
	float farDistance = *(float*)(renderer + LEVEL_RENDERER_FAR_DISTANCE_OFFSET);
	void* texture = getEarthTexture(levelRenderer);
	void* material = getEarthMaterial(levelRenderer);

	MatrixStackRef ref = MatrixStack$push(MatrixStack$World);
	float* m = ref.matrix;

	// X軸周りに90度回転 (四角形の法線を水平にする)
	for(int i = 0; i < 4; i++) {
		float column1 = m[4 + i];
		float column2 = m[8 + i];
		m[4 + i] = column2;
		m[8 + i] = -column1;
	}
	// 回転後の Y 軸方向へ空の遠くまで移動
	float distance = farDistance * 1.05f;
	for(int i = 0; i < 4; i++)
		m[12 + i] += m[4 + i] * distance;
	// 見かけの大きさに合わせて拡大
	float scale = farDistance * 2.1f * tanf(EARTH_ANGULAR_RADIUS * (float)M_PI / 180.0f);
	for(int i = 0; i < 12; i++)
		m[i] *= scale;
	*(bool*)(ref.stack + MATRIX_STACK_DIRTY_OFFSET) = true;

	Color white = {1.0f, 1.0f, 1.0f, 1.0f};
	ShaderColor$setColor(currentShaderColor, &white);

	mce$Mesh$render((void*)(renderer + LEVEL_RENDERER_SUN_MESH_OFFSET), material, texture, 0, 0);

	MatrixStackRef$destructor(&ref);
}

// void LevelRenderer::_renderSunOrMoon(bool isSun, float)
static void (*_LevelRenderer$_renderSunOrMoon)(void*, int, float);
static void LevelRenderer$_renderSunOrMoon(void* self, int isSun, float partialTicks) {
	// 月ディメンションでは太陽と月を描かない
	if(isMoonDimension(levelRendererDimension(self)))
		return;
	_LevelRenderer$_renderSunOrMoon(self, isSun, partialTicks);
}

// void LevelRenderer::_renderStars(float)
static void (*_LevelRenderer$_renderStars)(void*, float);
static void LevelRenderer$_renderStars(void* self, float partialTicks) {
	_LevelRenderer$_renderStars(self, partialTicks);
	// 地球は星の後に描いて、星より手前に見えるようにする
	if(isMoonDimension(levelRendererDimension(self)))
		renderEarth(self);
}

// void LevelRenderer::renderClouds(float)
static void (*_LevelRenderer$renderClouds)(void*, float);
static void LevelRenderer$renderClouds(void* self, float partialTicks) {
	if(isMoonDimension(levelRendererDimension(self)))
		return;
	_LevelRenderer$renderClouds(self, partialTicks);
}

// LevelRenderer::_setupFog(Entity const&, float)
// 元の処理は getFogColor の結果に明るさや高度による暗さを掛けるため、最後に色を上書きして #000000 ちょうどにする
static uintptr_t (*_LevelRenderer$_setupFog)(void*, void*, float);
static uintptr_t LevelRenderer$_setupFog(void* self, void* entity, float partialTicks) {
	uintptr_t result = _LevelRenderer$_setupFog(self, entity, partialTicks);

	if(isMoonDimension(levelRendererDimension(self))) {
		uint32_t fogFlags = *(uint32_t*)((uintptr_t)self + LEVEL_RENDERER_FOG_FLAGS_OFFSET);
		if((fogFlags & 0x00FF00FF) == 0)
			*(Color*)((uintptr_t)self + LEVEL_RENDERER_FOG_COLOR_OFFSET) = MOON_SKY_COLOR;
	}
	return result;
}

// ============================================================================

%ctor {
	VTAppPlatformiOS = (uintptr_t**)(0x1011695f0 + _dyld_get_image_vmaddr_slide(0));
	_AppPlatformiOS$readAssetFile = (std::string(*)(uintptr_t*, std::string const&)) VTAppPlatformiOS[58];
	VTAppPlatformiOS[58] = (uintptr_t*)&AppPlatformiOS$readAssetFile;

	Item$mItems = (Item***)(0x1012ae238 + _dyld_get_image_vmaddr_slide(0));
	Block$mBlocks = (Block**)(0x1012d1860 + _dyld_get_image_vmaddr_slide(0));
	BlockGraphics$mBlocks = (BlockGraphics**)(0x10126a100 + _dyld_get_image_vmaddr_slide(0));

	Block$mBlockLookupMap = (std::unordered_map<std::string, Block*>*)(0x1012d2078 + _dyld_get_image_vmaddr_slide(0));

	BlockItem$BlockItem = (BlockItem*(*)(BlockItem*, std::string const&, int))(0x1007281e0 + _dyld_get_image_vmaddr_slide(0));

	ItemInstance$ItemInstance = (ItemInstance*(*)(ItemInstance*, int, int, int))(0x100756c70 + _dyld_get_image_vmaddr_slide(0));

	Item$addCreativeItem = (void(*)(const ItemInstance&))(0x100745f10 + _dyld_get_image_vmaddr_slide(0));

	Block$Block = (Block*(*)(Block*, std::string const&, int, Material const&))(0x1007d7e20 + _dyld_get_image_vmaddr_slide(0));
	SandBlock$SandBlock = (Block*(*)(Block*, std::string const&, int))(0x10081d714 + _dyld_get_image_vmaddr_slide(0));

	Material$getMaterial = (Material&(*)(MaterialType))(0x1008c6e74 + _dyld_get_image_vmaddr_slide(0));

	BlockGraphics$BlockGraphics = (BlockGraphics*(*)(BlockGraphics*, std::string const&))(0x100388338 + _dyld_get_image_vmaddr_slide(0));
	BlockGraphics$setCarriedTextureItem = (void(*)(BlockGraphics*, std::string const&, std::string const&, std::string const&))(0x100382f0c + _dyld_get_image_vmaddr_slide(0));
	BlockGraphics$setTextureItem = (void(*)(BlockGraphics*, std::string const&, std::string const&, std::string const&, std::string const&, std::string const&, std::string const&))(0x1003829c8 + _dyld_get_image_vmaddr_slide(0));

	NormalDimension$NormalDimension = (void*(*)(void*, void*))(0x100855bdc + _dyld_get_image_vmaddr_slide(0));
	Level$getSeed = (unsigned int(*)(void*))(0x1007a98a4 + _dyld_get_image_vmaddr_slide(0));
	Level$getLevelStorage = (void*(*)(void*))(0x1007a9a9c + _dyld_get_image_vmaddr_slide(0));
	Level$requestPlayerChangeDimension = (void(*)(void*, void*, void**))(0x1007a49d4 + _dyld_get_image_vmaddr_slide(0));
	Entity$getLevel = (void*(*)(void*))(0x100656278 + _dyld_get_image_vmaddr_slide(0));
	Entity$getRegion = (BlockSource*(*)(void*))(0x100658034 + _dyld_get_image_vmaddr_slide(0));
	BlockSource$getBlockID = (BlockID(*)(BlockSource*, BlockPos const&))(0x10079a014 + _dyld_get_image_vmaddr_slide(0));
	BlockSource$hasChunksAt = (bool(*)(BlockSource*, BlockPos const&, int))(0x100799d5c + _dyld_get_image_vmaddr_slide(0));
	CompoundTag$putInt = (void(*)(void*, std::string const&, int))(0x10049aaa8 + _dyld_get_image_vmaddr_slide(0));
	CompoundTag$contains = (bool(*)(void*, std::string const&))(0x10049aebc + _dyld_get_image_vmaddr_slide(0));
	CompoundTag$getInt = (int(*)(void*, std::string const&))(0x10049b060 + _dyld_get_image_vmaddr_slide(0));

	MatrixStack$World = (void*)(0x101267688 + _dyld_get_image_vmaddr_slide(0));
	MatrixStack$push = (MatrixStackRef(*)(void*))(0x10003b950 + _dyld_get_image_vmaddr_slide(0));
	MatrixStackRef$destructor = (void(*)(MatrixStackRef*))(0x10003bc1c + _dyld_get_image_vmaddr_slide(0));
	currentShaderColor = (void*)(0x1012675a4 + _dyld_get_image_vmaddr_slide(0));
	ShaderColor$setColor = (void(*)(void*, Color const*))(0x1000283e4 + _dyld_get_image_vmaddr_slide(0));
	mce$Mesh$render = (void(*)(void*, void*, void*, int, int))(0x10003cae8 + _dyld_get_image_vmaddr_slide(0));
	mce$TexturePtr$TexturePtr = (void*(*)(void*, void*, ResourceLocation const&))(0x1000482ac + _dyld_get_image_vmaddr_slide(0));
	MinecraftClient$getTextures = (void*(*)(void*))(0x100085598 + _dyld_get_image_vmaddr_slide(0));
	mce$RenderMaterialGroup$common = (void*)(0x10126b6a8 + _dyld_get_image_vmaddr_slide(0));
	mce$MaterialPtr$MaterialPtr = (void*(*)(void*, void*, std::string const&))(0x10003b7d8 + _dyld_get_image_vmaddr_slide(0));

	MSHookFunction((void*)(0x1005316ec + _dyld_get_image_vmaddr_slide(0)), (void*)&File$exists, (void**)&_File$exists);

	MSHookFunction((void*)(0x100734d00 + _dyld_get_image_vmaddr_slide(0)), (void*)&Item$initCreativeItems, (void**)&_Item$initCreativeItems);
	MSHookFunction((void*)(0x100745f6c + _dyld_get_image_vmaddr_slide(0)), (void*)&Item$addBlockItems, (void**)&_Item$addBlockItems);
	MSHookFunction((void*)(0x100733348 + _dyld_get_image_vmaddr_slide(0)), (void*)&Item$registerItems, (void**)&_Item$registerItems);
	MSHookFunction((void*)(0x1007d451c + _dyld_get_image_vmaddr_slide(0)), (void*)&Block$initBlocks, (void**)&_Block$initBlocks);
	MSHookFunction((void*)(0x1003845e0 + _dyld_get_image_vmaddr_slide(0)), (void*)&BlockGraphics$initBlocks, (void**)&_BlockGraphics$initBlocks);

	MSHookFunction((void*)(0x100851844 + _dyld_get_image_vmaddr_slide(0)), (void*)&Dimension$Dimension, (void**)&_Dimension$Dimension);
	MSHookFunction((void*)(0x100851f84 + _dyld_get_image_vmaddr_slide(0)), (void*)&Dimension$createNew, (void**)&_Dimension$createNew);
	MSHookFunction((void*)(0x1008522d0 + _dyld_get_image_vmaddr_slide(0)), (void*)&Dimension$_createGenerator, (void**)&_Dimension$_createGenerator);
	MSHookFunction((void*)(0x100863394 + _dyld_get_image_vmaddr_slide(0)), (void*)&FlatLevelSource$loadChunk, (void**)&_FlatLevelSource$loadChunk);

	MSHookFunction((void*)(0x100746be0 + _dyld_get_image_vmaddr_slide(0)), (void*)&Item$useOn, (void**)&_Item$useOn);

	MSHookFunction((void*)(0x1007119a0 + _dyld_get_image_vmaddr_slide(0)), (void*)&Player$addAdditionalSaveData, (void**)&_Player$addAdditionalSaveData);
	MSHookFunction((void*)(0x100710e58 + _dyld_get_image_vmaddr_slide(0)), (void*)&Player$readAdditionalSaveData, (void**)&_Player$readAdditionalSaveData);
	MSHookFunction((void*)(0x1007a4770 + _dyld_get_image_vmaddr_slide(0)), (void*)&Level$createDimension, (void**)&_Level$createDimension);
	MSHookFunction((void*)(0x1007a7048 + _dyld_get_image_vmaddr_slide(0)), (void*)&Level$loadPlayer, (void**)&_Level$loadPlayer);

	MSHookFunction((void*)(0x1006a32ec + _dyld_get_image_vmaddr_slide(0)), (void*)&Mob$travel, (void**)&_Mob$travel);
	MSHookFunction((void*)(0x1006581d4 + _dyld_get_image_vmaddr_slide(0)), (void*)&Entity$move, (void**)&_Entity$move);
	MSHookFunction((void*)(0x1006a2d74 + _dyld_get_image_vmaddr_slide(0)), (void*)&Mob$causeFallDamage, (void**)&_Mob$causeFallDamage);
	MSHookFunction((void*)(0x1006ee84c + _dyld_get_image_vmaddr_slide(0)), (void*)&ProjectileComponent$tick, (void**)&_ProjectileComponent$tick);

	MSHookFunction((void*)(0x10079b854 + _dyld_get_image_vmaddr_slide(0)), (void*)&BlockSource$setBlockAndData, (void**)&_BlockSource$setBlockAndData);
	MSHookFunction((void*)(0x10072b180 + _dyld_get_image_vmaddr_slide(0)), (void*)&BucketItem$_emptyBucket, (void**)&_BucketItem$_emptyBucket);

	MSHookFunction((void*)(0x1007bd57c + _dyld_get_image_vmaddr_slide(0)), (void*)&Weather$tick, (void**)&_Weather$tick);

	MSHookFunction((void*)(0x100852dec + _dyld_get_image_vmaddr_slide(0)), (void*)&Dimension$getSkyColor, (void**)&_Dimension$getSkyColor);
	MSHookFunction((void*)(0x1008532c4 + _dyld_get_image_vmaddr_slide(0)), (void*)&Dimension$getStarBrightness, (void**)&_Dimension$getStarBrightness);
	MSHookFunction((void*)(0x100401820 + _dyld_get_image_vmaddr_slide(0)), (void*)&LevelRenderer$_renderSunOrMoon, (void**)&_LevelRenderer$_renderSunOrMoon);
	MSHookFunction((void*)(0x100401c18 + _dyld_get_image_vmaddr_slide(0)), (void*)&LevelRenderer$_renderStars, (void**)&_LevelRenderer$_renderStars);
	MSHookFunction((void*)(0x100401eb4 + _dyld_get_image_vmaddr_slide(0)), (void*)&LevelRenderer$renderClouds, (void**)&_LevelRenderer$renderClouds);
	MSHookFunction((void*)(0x1003f941c + _dyld_get_image_vmaddr_slide(0)), (void*)&LevelRenderer$_setupFog, (void**)&_LevelRenderer$_setupFog);
}
