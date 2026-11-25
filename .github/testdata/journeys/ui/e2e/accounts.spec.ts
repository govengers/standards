// covers: ui/src/pages/Users
// A spec of the miniature repository that templates.yml runs browser-select on (TST-020); never executed.
import { expect, test } from '@playwright/test'

test('an admin lists the users @smoke', async ({ page }) => {
  await page.goto('/users')
  await expect(page.getByRole('heading', { name: 'Users' })).toBeVisible()
})
