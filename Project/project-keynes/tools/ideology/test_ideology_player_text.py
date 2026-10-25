"""Regression checks for promises made by production ideology text.

Run: python -m unittest discover -s tools/ideology -p test_ideology_player_text.py
"""
import contextlib
import io
import unittest
from dataclasses import replace

import generate_ideology_catalog as catalog


class PlayerTextTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with contextlib.redirect_stdout(io.StringIO()):
            catalog.build_capability_dependent_tables()
            catalog.merge_x1_targets()
        catalog._PUBLISHED = catalog.published_cards()

    def program(self, key, level=0, row=0):
        return catalog.LEVEL_ROWS[key][level][row]

    def test_housing_is_a_household_consumption_category(self):
        text = catalog.player_program_summary(self.program('kin_hearth'))
        self.assertIn('居住维护消费需求提高 5%', text)
        self.assertNotIn('住房', text)
        self.assertIn('最多影响 32 个目标地块', text)

    def test_land_value_does_not_promise_unimplemented_land_prices(self):
        card = next(row for row in catalog.CARDS if row[0] == 'land_value')
        text = card[8]
        self.assertIn('地主对税负的承受能力', text)
        self.assertIn('居住维护消费需求', text)
        for unsupported in ('地价', '房租', '住宅', '地税'):
            self.assertNotIn(unsupported, text)
        summary = catalog.player_program_summary(self.program('land_value'))
        self.assertIn('居住维护消费需求提高 5%', summary)
        self.assertNotIn('地价', summary)

    def test_source_bonus_is_per_source_and_ceiling_is_separate(self):
        program = replace(self.program('communal_feast'),
                          summary='主产野味、鱼和采集物：出生率固定提高 9%')
        text = catalog.player_program_summary(program)
        self.assertIn('出生率提高 3%', text)
        self.assertIn('出生率最高提高 9%', text)
        self.assertIn('主产野味', text)
        self.assertNotIn('采集物', text)
        self.assertNotIn('鱼', text)

    def test_wood_and_logs_are_distinct_goods(self):
        text = catalog.player_program_summary(self.program('coppice_rotation'))
        self.assertIn('主产木材', text)
        self.assertIn('木材产出降低 6%', text)
        self.assertNotIn('原木', text)

    def test_phantom_cost_in_author_note_is_not_published(self):
        text = catalog.player_program_summary(self.program('space_mining'))
        self.assertIn('采掘产出提高 6%', text)
        self.assertNotIn('资源消耗', text)

    def test_fractional_ramp_limit_is_not_a_fractional_cell_count(self):
        for key in ('salt_monopoly', 'semiconductor'):
            text = catalog.player_program_summary(self.program(key, 2))
            self.assertIn('最高提高', text)
            self.assertNotIn('7.5 个', text)
            self.assertNotIn('13.3334 个', text)

    def test_shortage_does_not_claim_exhausted_resource_deposits(self):
        text = catalog.player_program_summary(self.program('ecological_balance', row=1))
        self.assertIn('货物最高短缺率至少 30%', text)
        self.assertNotIn('枯竭', text)

    def test_neighbour_population_is_a_sum_and_class_opinion_is_national(self):
        text = catalog.player_program_summary(self.program('village_compact'))
        self.assertIn('周围 1 格内人口合计至少 800 人', text)
        text = catalog.player_program_summary(self.program('trade_unions'))
        self.assertIn('全国工人阶层满意度', text)

    def test_unsupported_shape_fails_before_emission(self):
        with self.assertRaises(SystemExit):
            catalog.player_program_summary(replace(self.program('kin_hearth'),
                                                    tags=('cell.nonexistent',)))
        with self.assertRaises(SystemExit):
            catalog.player_program_summary(replace(self.program('kin_hearth'),
                                                    max_stacks=3))

    def test_every_published_program_and_rule_has_a_reviewed_shape(self):
        catalog.validate_player_text()
        self.assertEqual(len(catalog.cards_to_emit()), 113)
        self.assertEqual(len(catalog.all_card_programs()), 280)


if __name__ == '__main__':
    unittest.main()
