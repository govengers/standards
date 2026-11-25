// covers: ui/src/pages/Board ui/src/pages/Task changelog
// A spec of the miniature repository that templates.yml runs browser-select on (TST-020); never executed.
import { expect, test } from '@playwright/test'

test('a task moves across the board', async ({ page }) => {
  await page.goto('/board')
  await expect(page.getByRole('heading', { name: 'Board' })).toBeVisible()
})
