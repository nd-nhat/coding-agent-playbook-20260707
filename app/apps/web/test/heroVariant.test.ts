import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heroVariant } from '../src/steps/heroVariant.ts';

test('正の差額は good（安くなる見込み）', () => {
  assert.equal(heroVariant(12000), 'good');
});

test('負の差額は bad（高くなる見込み）', () => {
  assert.equal(heroVariant(-8000), 'bad');
});

test('差額 0 は even（損益分岐）', () => {
  assert.equal(heroVariant(0), 'even');
});

test('yen() で ￥0 表示になる準損益分岐（±0.49 円）も even', () => {
  assert.equal(heroVariant(0.49), 'even');
  assert.equal(heroVariant(-0.49), 'even');
});

test('yen() で ￥1 表示になる差額（±0.5 円）は even にしない', () => {
  assert.equal(heroVariant(0.5), 'good');
  assert.equal(heroVariant(-0.5), 'bad');
});
